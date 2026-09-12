<!-- UNTRACKED, DURABLE COPY of the Pyrelisk three-phase design (frozen contract §7, v2 delta, Appendix K). Source of truth for the redesign; the /tmp scratchpad original does not survive across days. Commit by explicit path with the Pyrelisk unit. -->

# Pyrelisk, the Ashfall Colossus — the three-act redesign

Written 2026-09-12 against the **worktree**, not HEAD. The Pyrelisk lane's v2
remake, rig retune and seam system are uncommitted; everything cited below is
cited at its worktree line. `assets/boss_gen.py` was `Sep 11 23:58:33 2026` at
the start and end of the read that produced §7 — it did not move under us.

This is a DESIGN. Nothing here has been written to the repo.

---

## v2 delta (2026-09-12, after the Pyrelisk lane's review — ACCEPT with changes)

1. **`armfall` is gone from `phases[2]`.** Act 2 is entered by the meter
   cash-out calling `Fn.pyreliskDropArms`, never by a selected attack. A phase
   row whose only entry was a pseudo-move would leave the 120-second failure
   re-entry at 0.70 with nothing to cast. `phases[2]` now carries the act-1
   book and the scarred-flank latch prunes it down to the whole-body moves.
   (§2.1, §3.1.)
2. **The 0.15 flank chip fires on the `SeamsBroken` 0→1 TRANSITION, not on
   meter-full.** At most twice, ever. Failure cycles now pin health at exactly
   0.70 and the "strictly cheaper, never resets" property holds. The re-cycle
   gate is specified: with both flanks already scarred, **either** meter
   re-filling returns the arms. (§2.2, §3.1.)
3. **`WeatherController.luau` joins the file list** — an `ARENA_MOOD_BOUNDS`
   entry and a mood of its own for the heart room, paired with the lighting
   override §6.1 already cites. (§8.1, §8.5 slice 6.)
4. **The `parts.mounts` triples are marked DEAD VALUES**, to be regenerated from
   `armJoints`-at-`fallen` once slice 2 prints the HANDOFF. Never pasted. (§3.2.)
5. **The F-13 gate gains a fourth equality**, so the whole chip ledger is
   asserted to sum to 1.0 rather than only to match the thresholds. (§9.3.)
6. **`ATTR.PHASE_INDEX` is NOT reused on the heart — §7.3 is re-frozen.** The
   verification the runtime lane owed came back negative: the value 3 is not a
   plain discriminant. See §7.5.
7. **Flag ownership is recorded** against every flag in §9.3, and F-14 gains a
   structural fix rather than a playtest.

---

## 0. The directive, and what it asks of the engine

> "in the 3rd phase you get to go inside the volcano. modify the boss's attack
> logic and idea so that theres the first 2 phases which are outside and the
> first phase you have to shoot the seams in the boss's body then when the seams
> are shot it stuns the boss for a super long time and then the arms come down
> and you have to kill both arms. then phase 2 starts where you have to actually
> mount the boss. when both arms are killed, the final arm you kill will still
> remain but you have to climb it and now it starts a section where as you climb
> up the arm (which is flat and easy to climb), you have to like kill like orange
> rocks on it and you kill them all while going up to the neck where you kill a
> big orange rock on its neck and then you jump off his neck as he goes down in
> the volcano but then the volcano opens up and then you have to like jump in and
> once you're in you have the 3rd phase inside the volcano where you're in its
> heart and you have to like break obsidian pillars while getting shot at by
> something or something like that. redesign the boss to allow for this type of
> idea."

Six beats, and every one of them has a shipped mechanism waiting for it:

| the beat | the shipped mechanism | where |
|---|---|---|
| shoot the seams | the seam system, whole | `Fn.pyreliskSeamOnRay` / `SeamCredit`, CreatureService L1065-1157 |
| a super-long stun | `openStagger` takes a per-source duration | `Fn.openStagger(creature, def, now, seconds)`, L7545 |
| arms come down, kill both | `parts` + `partOf` + `partsAlive` + `vulnerableWhen` | `Fn.spawnBossParts` L13648; `Fn.unaimable` L842 |
| mount and climb | the mount layer | `Fn.openPyreliskMount` L6933, `PyreliskPath.climbSlabs` L1154 |
| orange rocks / neck rock | part-creatures on a no-op archetype | `krakenpolyp` / `choirstalk`, `ARCHETYPE_UPDATERS` L16770-16786 |
| go inside, phase 3 | `ArenaMove` to a second arena | `Fn.krakenSwallow` L15535; `BossService` L954 |

**Nothing in this design needs a new engine.** It needs a pose, a second arena,
six creature rows, five attribute names and a re-pointing of numbers that
already exist. That is the whole claim, and §8 is the audit of it.

---

## 1. The phase flow

```
                    ┌─────────────────────────────────────────────────────────┐
  ACT 1  stance 3   │ THE SHELL                    health 1.00 → 0.70         │
  PyreliskAct = 1   │ rim path, r120-232. Body untargetable (entrenched).     │
                    │ Six flank seams open on attack windups. Fill BOTH flank │
                    │ meters. Each full meter scars that flank permanently    │
                    │ (SeamsBroken) and costs the colossus that arm's moves.  │
                    └──────────────────────┬──────────────────────────────────┘
                       both meters full ───┘
                    ┌─────────────────────────────────────────────────────────┐
  ACT 2  stance 2   │ THE STUN AND THE ARMS        health 0.70 → 0.30         │
  PyreliskAct = 2   │ Both arms crash across the moat onto the rim path and   │
                    │ become two `pyrelisk_arm` creatures. The colossus does  │
                    │ NOTHING for as long as they stand (cap 120s). The arms  │
                    │ shed lava pools; the summit keeps raining ash.          │
                    └──────────────────────┬──────────────────────────────────┘
                        both arms dead ────┘
                    ┌─────────────────────────────────────────────────────────┐
  ACT 3  stance 1   │ THE CLIMB                    health 0.30 → 0.00         │
  PyreliskAct = 3   │ The SECOND arm to die stays. The colossus goes          │
  Planted = ±1      │ prostrate (the `fallen` pose): shoulder to y 40, so the │
                    │ arm lies at 19.8 degrees, 18 studs wide. Climb it.      │
                    │ Six `pyrelisk_ventrock` on the arm; one                 │
                    │ `pyrelisk_neckcore` at the collar. Kill all seven.      │
                    └──────────────────────┬──────────────────────────────────┘
                       neck core dies ─────┘  (this is the colossus's death)
                    ┌─────────────────────────────────────────────────────────┐
  THE DROP          │ THE CALDERA OPENS            PyreliskAct = 4            │
  PyreliskCaldera=1 │ beginBossCollapse holds the death open for              │
                    │ `collapseFor` while the body sinks into the lake. The   │
                    │ lava drains, the lake floor goes, a 120-stud shaft is   │
                    │ under it. Jump in.                                      │
                    └──────────────────────┬──────────────────────────────────┘
                    succeededBy = "pyrelisk_heart"   +   per-player ArenaMove
                    ┌─────────────────────────────────────────────────────────┐
  ACT 4             │ THE HEART                    arena `pyrelisk_heart`     │
  PyreliskAct = 4   │ A closed room, r 96, 600 studs up like the gullet.      │
                    │ Eight obsidian pillars (`pyrelisk_pillar`). The heart   │
                    │ is untouchable while any stands (`vulnerableWhen =      │
                    │ "partsDown"`). Six wall vents throw globs at you the    │
                    │ whole time. Every pillar broken vents a permanent lava  │
                    │ pool at its own socket and steps the vents' cadence.    │
                    │ Heart dies -> Heart_pyrelisk, via `heartAs`.            │
                    └─────────────────────────────────────────────────────────┘
```

### 1.1 Why the act index rides the health bar, and no new phase field exists

The coordinator's constraint 3 asked that this use the entrenched engine rather
than invent a parallel phase field. It does, and the fit is exact.

`Fn.bossPhaseFraction` (L4044) returns `creature.health / creature.maxHealth`
for every boss but the Wrack. `bossPhaseIndex` (L6626) turns that into the
`phases` row index, and the colossus tick (L16082-16086) turns *that* into
`ATTR.STANCE = (def.stances or 1) - (index - 1)` — the shipped line, untouched.

So if each milestone chips an exact fraction off the colossus's own bar, the
stance machinery already shipped tells the exact truth about the act:

| milestone | chip | running health | stance | `phases` row |
|---|---|---|---|---|
| — | — | 1.00 | 3 | `below = 1.0` |
| left flank meter full | 0.15 | 0.85 | 3 | |
| right flank meter full | 0.15 | **0.70** | **2** | `below = 0.70` |
| first arm dies | 0.20 | 0.50 | 2 | |
| second arm dies | 0.20 | **0.30** | **1** | `below = 0.30` |
| six vent rocks | 6 × 0.05 | 0.00 | 1 | |
| neck core dies | health := 0 | dead | — | |

The two thresholds move from `0.66 / 0.33` to `0.70 / 0.30`, and the arithmetic
above is why: `0.30 + 0.40 + 0.30` are the three acts' chips, and they must land
exactly on the boundaries or a stance change fires inside an act.

**`K.PY_VENT_FRACTION = 0.07` is the precedent for the whole mechanism** — the
existing vent smash already takes a fraction off the boss rather than damaging
it. This is that idea, six times, with the numbers re-derived.

**No `machine` block, no `actFraction`, no `PyreliskPhase` number.** The one new
attribute (`PyreliskAct`) is a *statement for the client*, not the server's
state: the server's state is the health bar, `partsAlive` and `state.planted`,
all of which already exist. See §4 for why the client still needs it.

### 1.2 What a late-joining client sees

Everything is a LEVEL, per the Wrack rule (`WRACK_ACT`, `WRACK_DIVE`, the
`WeakpointHot` idiom). A client adopting the fight at any instant reads:
`PyreliskAct` (which act), `Stance` (the same thing, redundantly, off the
shipped path), `SeamsOpen` / `SeamsBroken` / `SeamMeterL` / `SeamMeterR` (the
shell's state), `Planted` (which arm is the ramp), `PyreliskArmL` / `PyreliskArmR`
(each arm's bar), `PyreliskRocks` (the bitmask of surviving arm rocks),
`PyreliskCore` (the neck core's bar), and on the arena model `PyreliskCaldera`.
There is no edge anywhere in the contract that, if missed, leaves a client
drawing the wrong fight.

---

## 2. Act 1 — the shell

### 2.1 The attack book

The shipped five stay, with their `seams` fields unchanged. They are already the
right book for "the boss is invulnerable and its attack windups are your only
shooting window": `handfall` and `shardhurl` open one flank, `ventbreath` and
`ashfall` open both.

```
phases = {
  { below = 1.0,  attacks = { "handfall", "rimsweep", "shardhurl", "ventbreath" } },
  -- ACT 2 IS NOT ENTERED BY AN ATTACK, and this row carries the act-1 book
  -- rather than a pseudo-move. See §3.1: the act begins when the meter
  -- cash-out calls Fn.pyreliskDropArms, and while the stun holds, the boss
  -- picks nothing at all (`mode == "stagger"` returns before the pick).
  --
  -- SO WHAT IS THIS ROW FOR? The 120-second FAILURE branch. When the arms
  -- survive the window they withdraw, the colossus stands back up at exactly
  -- health 0.70, and `Fn.pickBossAttack` starts drawing from THIS row. A row
  -- holding only `armfall` would hand it an attack with no handler; a row
  -- holding the act-1 book hands it the fight it is returning to. The
  -- scarred-flank latch (§2.1) prunes it to the whole-body moves on its own,
  -- because by definition both flanks are scarred by the time this row can
  -- ever be read - so what actually gets cast here is `ventbreath` and
  -- `ashfall`, and that is the correct pool for a two-armed colossus that has
  -- lost the use of both arms.
  { below = 0.70, attacks = { "handfall", "rimsweep", "shardhurl", "ventbreath", "ashfall" } },
  { below = 0.30, attacks = { "ashfall", "ventbreath", "crownshed" } }, -- act 3: the climb
}
```

> **`phases[1]` is the fallback within a pool**, the project-wide rule
> (`Fn.pickBossAttack` returns `attacks[1]` when everything else is cooling).
> Row 2 leads with `handfall` for the same reason row 1 does — but note that a
> latch which refuses both scarred flanks must still return SOMETHING, so
> `pyreliskLatch`'s new preference is a preference and not a gate: with both
> flanks scarred it falls through to its existing behaviour. A hard gate there
> would be the empty-pool bug one level down.

Three changes to act 1's book, and they are the only changes to the five moves:

1. **`ventbreath` moves into phase 1.** It is the longest seam window in the book
   (2.4 + 2.6s, both flanks) and act 1 is now the *whole* seam game, so the move
   that offers the most seam uptime cannot be locked behind a threshold the seams
   are what cross.
2. **A scarred flank cannot commit.** `pyreliskLatch` (L9949) picks `aimSide`;
   it gains one line that prefers the unscarred flank when `state.seamsBroken`
   has one flank's mask and not the other. Readable, and it is the reward for
   breaking a flank: the colossus visibly stops using that arm. `ashfall` and
   `ventbreath` are whole-body and are unaffected, so a party that breaks one
   flank early does not run out of things to shoot.
3. **`handfall`'s bait is re-pointed, not deleted.** Today a fist that lands
   beside a monolith shatters it and opens a 20-second window (`stoneReach = 30`,
   `stagger = 20.0`, `Fn.spendStone`). There is no window to open in act 1 any
   more — the body is untargetable and stays that way. So the bait now pays
   **seam meter**: a new row field `seamCredit = 0.40` means a spent monolith
   fills 40% of the committing flank's meter outright. The nine stones, the
   `stoneReach = 30` derivation off the fist's r 188 band, `Fn.spendStone`,
   `Fn.regrowStones` and `Fn.restoreStones` all survive and all keep meaning
   what they meant. `stagger` and `weakStagger` come off the `handfall` row.

   > This resolves the checklist's open item *"Window-only damage is an open
   > design decision… that may be the fight, or it may be why it feels long."*
   > Act 1 has no punish window at all now. The window is act 2, and it is
   > ninety seconds long.

### 2.2 The seam meters

`K.PY_SEAM_METER_HP` goes **2600 → 5400**, per flank, and **gains party
scaling**, which it does not have today:

```lua
-- Fn.pyreliskSeamCredit, L1142
local meter = (state[key] or 0) + amount / (K.PY_SEAM_METER_HP * Fn.partyMult(creature))
```

where `Fn.partyMult(creature)` is `(creature.extra and creature.extra.healthMult) or 1`.
**This is a real gap today**: `Fn.spawnBossParts` (L13710-13718) already passes
`healthMult` down to every part, with a comment saying a wall that stayed
solo-sized "would make the fight EASIER per head as the party grew, which is
backwards" — and the seam meters are the biggest wall in the redesigned fight
and are not scaled at all. Flag F-1.

Why 5400 and not 2600: a flank meter is now ~15% of the fight rather than a
repeatable window, and there are two of them, so 10,800 of seam damage is act 1
in its entirety. At 2600 each, act 1 would be over in under thirty seconds.
Flag F-2 (this number is a guess against an unmeasured DPS).

A full meter no longer calls `openStagger`. The cash-out at L16063 becomes:

```lua
if def.pose == "pyrelisk" and creature.seamBreakSide and not creature.collapsing then
    local side = creature.seamBreakSide
    creature.seamBreakSide = nil
    -- THE CHIP IS ON THE SCAR'S 0 -> 1 TRANSITION, NOT ON THE METER FILLING.
    -- `Fn.pyreliskSeamCredit` (L1148) ors this flank's mask into
    -- `state.seamsBroken`, which is MONOTONIC and therefore idempotent - so
    -- asking "was this bit already set?" is asking "have we ever paid for this
    -- flank?", and the answer is no exactly twice in the life of a fight.
    --
    -- WHY THIS IS NOT THE SAME AS CHIPPING ON METER-FULL. The 120-second
    -- failure branch (§3.1) clears the meters and lets a party re-fill one.
    -- Paid on meter-full, a second fill would chip a second 0.15 and the
    -- colossus's bar would walk down through 0.55, 0.40, 0.25 on cycles that
    -- were supposed to cost nothing but time - which breaks the stance
    -- arithmetic (§1.1) silently, firing a stance banner and swapping the
    -- attack pool in the middle of act 1. Paid on the transition, health is
    -- PINNED at exactly 0.70 for every cycle after the first, which is what
    -- makes "a second cycle is strictly cheaper, and nothing resets" true
    -- rather than aspirational.
    if not Fn.pyreliskFlankPaid(creature, side) then
        Fn.pyreliskMarkFlankPaid(creature, side)
        Fn.pyreliskChip(creature, def, K.PY_FLANK_FRACTION)   -- 0.15, at most twice
    end
    -- THE DROP GATE, and it is deliberately NOT "this cash-out completed the
    -- pair". It is a LEVEL test on the scar mask, which is what makes the
    -- re-cycle work: see below.
    if Fn.pyreliskBothFlanksBroken(state) and not creature.pyreliskArmsOut then
        Fn.pyreliskDropArms(creature, def, now)           -- act 2 begins
    end
end
```

`Fn.pyreliskFlankPaid(creature, side)` / `Fn.pyreliskMarkFlankPaid` are a
two-bit mask on the creature record (`creature.pyreliskFlanksPaid`), not on
`state` — the scar mask is the client's contract and must not grow a second
meaning. Two `Fn` fields, no new locals.

**The re-cycle gate.** After a failed window, both flanks are already scarred and
`SeamsBroken` cannot go back (it is monotonic, and this design does not break
that). So the gate cannot be "the pair just completed" — that edge already
happened and will never happen again. It is the level test above:

> **With both flanks already scarred, EITHER meter re-filling returns the arms.**

`creature.pyreliskArmsOut` is the re-arm latch: `Fn.pyreliskDropArms` sets it,
the failure branch clears it as it retires the arms, and `Fn.pyreliskArmsDone`
leaves it set forever (act 3 is one-way). So a party that lost the first window
re-earns it by filling *one* meter, not two — which is the right price for a
retry and is why the meters are cleared on failure rather than left full.

This also means the act-2 entry has exactly one call site and one guard, and
neither of them is an edge. A late-joining client that adopts during a re-cycle
reads `SeamsBroken` (both flanks, scarred), `PyreliskAct` (1), `SeamMeterL/R`
(one of them climbing) and draws the correct fight with no history.

`Fn.pyreliskChip(creature, def, fraction)` is the one new primitive the whole
design turns on, and it is ten lines: subtract `fraction * creature.maxHealth`
from `creature.health`, floor at a hair above zero unless the caller says
otherwise, republish `ATTR.HEALTH`. It is the vent smash's existing arithmetic
(`K.PY_VENT_FRACTION`) lifted into a named function so six call sites share it.

---

## 3. Act 2 — the stun and the arms

### 3.1 The stun's duration: it is the arms, capped at 120 seconds

The directive says "a super long time". A fixed number would be either a
softlock risk (too short: the arms survive, and nothing in the design says what
happens) or dead air (too long: the arms die and the party waits). So:

> **The stun lasts until both arms are dead, capped at `K.PY_ARM_WINDOW = 120`
> seconds.**

`Fn.openStagger(creature, def, now, K.PY_ARM_WINDOW)` opens it — one call, the
shipped function, with its per-source duration used exactly as the coordinator's
constraint 3 asks. `setMode(creature, "stagger", 120, now)` means the colossus's
`mode == "stagger"` branch (L16106) runs for the whole act, `Exposed` is stamped,
`untargetable` is false, and `Fn.placeColossus` holds the slump pose. All shipped.

Two additions:

* **The window ends early when both arms die.** `kill()`'s `partOf` path already
  counts `partsAlive` down and stamps `ATTR.EXPOSED` at zero (L1404-1455). The
  colossus tick checks `creature.partsAlive == 0 and creature.mode == "stagger"`
  and advances to act 3 rather than letting the 120 run out.
* **The window expiring is the failure branch, and it is not a reset.** At 120
  seconds with arms still standing, `Fn.krakenRetireArm`'s idiom (L15583) takes
  them off the board with no kill and no loot, the colossus stands back up, and
  the fight returns to act 1 — with the flank meters cleared, `creature.pyreliskArmsOut`
  cleared, and **`SeamsBroken` untouched**. The scar mask is documented monotonic
  ("bits are only ever set, never cleared, for the life of the fight",
  PyreliskBodyController L106) and this design does not break that invariant:
  the scars accumulate visibly across cycles while the meters reset.

  **Health is pinned at exactly 0.70 across every cycle after the first**,
  because the 0.15 chips are paid on the scar's 0→1 transition and not on the
  meter filling (§2.2). The colossus re-enters `phases[2]`, whose pool is the
  act-1 book pruned by the scarred-flank latch to `ventbreath` and `ashfall` —
  the correct fight for a colossus that has lost the use of both arms and has
  not yet had them taken off it.

  **Re-entry costs ONE meter, not two.** With both flanks already scarred the
  drop gate is a level test, so the next meter to fill returns the arms. They
  come back at full health with the chips already spent, so a second cycle is
  strictly cheaper in the bar and strictly cheaper in the seam work. Health
  never goes back up — `Fn.pyreliskChip` is one-way.

Why 120: the longest thing in the shipped book is `handfall.stagger = 20.0`,
described in the row as "the most important number in the file… the window is a
journey, not a burst". 120 is six times that, and it is the only stretch of the
fight in which the colossus does nothing at all — unmistakably "super long"
against the fight's own vocabulary. Against the arms' HP (§3.3) it is ~1.6× the
time a solo player is projected to need. Flag F-3: 120 and the arm HP are one
decision, re-derive both from a measured party DPS.

### 3.2 The arms arrive

`Fn.pyreliskDropArms(creature, def, now)`:

1. `state.armsDown = true`, `state.planted = 0` (neither arm is the ramp yet —
   both are down).
2. `Fn.spawnBossParts(creature, def)` with the new `parts` block (§6.2).
3. `Fn.openStagger(creature, def, now, K.PY_ARM_WINDOW)`.
4. `model:SetAttribute(ATTR.PY_ACT, 2)`.
5. `fireEvent("bossStance", ...)` — the shipped banner.

**Positioning.** `parts.at = "mounts"` resolves the offsets once against
`creature.yaw0` and `Fn.spawnBossParts`' own comment (L13680-13692) warns that
"a colossus that slews needs its parts re-placed as it turns, and should not use
this mode until that exists." That warning does not bite here, and the reason is
the mount layer's own rule, **extended**: the body is frozen for the whole of
acts 2 and 3. The shipped rule is not enough on its own — it fires only while
`planted ~= 0`, and act 2 has `planted == 0` — so F-14's structural fix
(hard-pin `bearing` / `breath` / `lean` on `planted ~= 0 OR act >= 2`, §9.3)
is a PREREQUISITE of this section and lands in slice 2.
`Fn.openPyreliskMount` pins `faceAngle` at the instant the window opens, and
PyreliskPath switches `breath` and `lean` off while an arm is planted, precisely
so a player standing on an anchored slab does not have the body swing out from
under them. A frozen boss has one heading, so a once-resolved mount is correct
by construction — and the design must state that dependency out loud, because
the day someone lets the colossus turn in act 2 is the day the arms teleport.

So: **`parts.at = "mounts"`, two entries, resolved once, valid because the body
is frozen.** The mounts are boss-local at the *fallen* pose's fist positions:

```lua
parts = {
    row = "pyrelisk_arm",
    count = 2,
    at = "mounts",
    mounts = {
        -- ########## DEAD VALUES. DO NOT PASTE THESE. ##########
        -- ARITHMETIC OFF §5.2's UNBUILT POSE, written here only so the shape
        -- of the block is legible. They are wrong by construction the moment
        -- the `fallen` pose exists, because they were solved against a
        -- shoulder height and a fist radius that were CHOSEN (F-8, F-9) and
        -- not MEASURED.
        --
        -- REGENERATE, NEVER COPY. Slice 2's boss_gen HANDOFF prints the fallen
        -- pose's joints ("FALLEN shoulder / elbow / wrist / fist"); these two
        -- lines are `PyreliskPath.armJoints(state, side).fist` at that pose,
        -- per flank, taken through the body's inverse transform. The repo's
        -- own law is the whole reason this warning exists: a number derived
        -- from a constant is a CLAIM; measured off the built objects it is
        -- EVIDENCE (boss_gen L3930).
        Vector3.new(183.0, 3.0,  62.0),   -- DEAD: flank +1
        Vector3.new(183.0, 3.0, -62.0),   -- DEAD: flank -1
        -- ######################################################
    },
    -- NO `regrow`. The absence is the act boundary, exactly as it is on
    -- Bosses.admiral_wrack: with nothing to reset the count, the second kill
    -- opens act 3 forever.
}
```

**F-4, and the preferred resolution is to DELETE the `at`/`mounts` block rather
than to fix it.** `Fn.pyreliskDropArms` should place both parts from
`PyreliskPath.armJoints(state, side)` at the live `fallen` pose — the
`Fn.plantKrakenArm` (L14505) single-part form — for the same reason the arm
rocks are placed from the path module and not from `parts.mounts` (§4.3): a
mounts list cannot express "mirrored by flank", and it is a second copy of
geometry the path module already owns, to be got wrong separately. The `parts`
block then keeps only `row`, `count` and the absent `regrow`.

The literal triples survive in this document as a SHAPE, not as data. If they
reach `Bosses.luau` in any form other than regenerated-from-HANDOFF, that is the
bug — and it is the mirrored-monolith bug (the checklist's first trap) with a
different set of nine numbers.

### 3.3 What the arms are

`Creatures.items.pyrelisk_arm`:

```lua
{
    id = "pyrelisk_arm",
    name = "Ashfall Limb",
    rarity = "Boss",
    archetype = "pyreliskarm",     -- a ~30-line updater, see below
    health = 7000,
    waters = "volcano",
    shotRadius = 14.0,             -- 150 studs of limb lying across the path
    rewards = { coins = { 240, 380 }, xp = 600 },
    -- NOT rangedOnly: the arms lie ON the rim path at the party's feet, which
    -- is the first melee this fight has ever offered. The moat made the whole
    -- of act 1 ranged-only by geometry (hitRadius 96 + a 16-stud reach is
    -- eight studs inside the lake's edge); the arms are the answer to that,
    -- and a `rangedOnly` flag here would take it back.
    body = { model = "CreaturePack", species = "Pyrelisk", shape = "leviathan",
             stance = "upright", scale = 2.2,
             color = ..., finColor = ..., markColor = Color3.fromRGB(255, 96, 16) },
}
```

**`shotRadius = 14` is a capsule problem, not a sphere problem.** A limb 150
studs long captured by a 14-stud sphere at its fist means the elbow end is not
shootable. The shipped answer exists: `creature.hitHeight` (set at L15904 for the
colossus itself, consumed at L1203-1246 of `raycastNearest`) turns the pivot into
a vertical *axis*. It is vertical only, and these arms lie flat. Two options:

* **(a) Ship it as a sphere at the fist and accept that you fight the hand.**
  The fist is where the arm meets the rim path, which is where the party is
  standing, and it is where every telegraph in act 2 already points. Zero code.
* **(b) Generalise `hitHeight` to `hitAxis: Vector3?`.** Eight lines in
  `raycastNearest`, and it is the correct fix — the same one the pyrelisk
  checklist already owes for the colossus ("The fix is a pivot-to-crown capsule
  in `raycastNearest`").

**Take (a) for slice 3 and (b) as a follow-on.** Flag F-5.

**The `pyreliskarm` archetype.** `krakenarm` and `krakenpolyp` are
`function() end` (L16785-16786) and a no-op is nearly right: the arms are dead
weight on the ground. But an act with 120 seconds of zero pressure is not a
fight, it is a damage check, so the arms get one behaviour and one only:

```
Fn.updatePyreliskArm(creature, dt, now)   -- ~30 lines, beside the other Fn.py* helpers
  every K.PY_ARM_POOL_GAP (7.0) seconds:
    pick a point on the rim path within K.PY_ARM_POOL_R (55) of this arm,
    fire a "mark" telegraph (an existing CreatureEventController branch)
    with K.PY_ARM_POOL_ARM (1.4) seconds of warning,
    then leave a lava pool: the shipped `ventbreath.pool` shape
    { radius = 13, duration = 9, min = 14, max = 20, skin = "lava" }.
```

That is the whole hazard: the arms are bleeding onto the ground you have to
stand on to hit them, and the ground shrinks. It is the Pyrelisk signature
(`ventbreath`'s "the move that permanently takes path away") turned into the
act's clock, and it reuses the `mark` telegraph and the pool primitive whole.

### 3.4 The fallen pose, and why act 2 is where it starts

The moment the arms come down the colossus goes prostrate. This is one new pose
in `PyreliskPath` (`fallen`, a keyframe track like the five attacks) and it is
the load-bearing geometry of the entire back half of the fight, because it is
what makes the climb "flat and easy". §5 is its arithmetic.

In act 2 the fallen pose is held at `blend = 1`, both arms down, `planted = 0`.
In act 3 it is the same pose with `planted = ±1`.

---

## 4. Act 3 — the climb

### 4.1 Which arm remains

The **second arm to die** is the ramp. `kill()`'s `partOf` decrement is where
this is known: when `owner.partsAlive` hits 0, the arm being killed is the one
that stays. `Fn.pyreliskDropArms` stashes each part's flank on the part record
(`part.pyreliskSide`), and the act-3 entry reads the last one:

```lua
state.planted = creature.pyreliskLastArmSide      -- +1 or -1
creature.model:SetAttribute(ATTR.PLANTED, state.planted)
```

**`ATTR.PLANTED` is reused, not duplicated.** It already means exactly "which
flank is the climb ramp" (`K.RIG_POSE.pyrelisk.planted = true`, L6718-6722;
`PyreliskPath.rampCFrame` reads `state.planted`), the client already draws off
it, and the design adds no `PyreliskRamp` field.

The dead arm's *creature* is gone (it died). What remains is the drawn limb and
the invisible climb slabs, which is exactly what remains today after a baited
`handfall` — the mount layer has never needed the arm to be an entity.

### 4.2 The mount layer, re-pointed

`Fn.updatePyreliskMount` (L7040) gates on
`creature.mode == "stagger" and (state.planted or 0) ~= 0 and not creature.collapsing`.
Act 3 is not a stagger — it is the rest of the fight — so the gate becomes:

```lua
local mounted = (state.planted or 0) ~= 0 and not creature.collapsing
    and (creature.mode == "stagger" or creature.pyreliskAct == 3)
```

Everything downstream is unchanged: `Fn.openPyreliskMount` builds the slabs from
`PyreliskPath.climbSlabs(state)`, `Fn.pyreliskLavaWatch` keeps its damage-and-rescue
contract (`K.PY_LAKE_R` 120, `K.PY_LAVA_HEAD` 16, rescue to `K.PY_RESCUE_R` 150),
and `clearPyreliskMount` still fills the forward declaration at L749 so
`removeOwnedParts` and `kill` can both reach it.

**Two things retire.**

* `Fn.shakePyreliskMount`'s throw-everyone-off is no longer an exit — act 3 ends
  when the neck core dies, and the party should be standing on the neck when it
  does. It stays wired for the collapse and for the 120-second failure branch.
* **The vent-smash minigame retires entirely.** `Fn.pyreliskVentSwing` (L7131),
  its second listener on `Remotes.RequestAttack`, `pyreliskSwingAt`,
  `K.PY_VENT_REACH`, `K.PY_VENT_HITS`, `K.PY_VENT_FRACTION` and `K.PY_SWING_GAP`
  all go. Per the coordinator's constraint 1, the vent geometry is a free
  variable and the back-vent mount game is superseded. The three
  `PyreliskPath.VENTS` sites and the `Pyrelisk_Vent` module **survive as
  hazards**: in act 3 they fire straight up on a clock (a `mark` telegraph, then
  a pool on the deck), which is the pressure while you cross the back.

  Retiring the `RequestAttack` listener is a net simplification — it was the one
  place in the project where a remote bypassed CombatService's weapon cooldown
  and needed its own rate limit.

### 4.3 The orange rocks

Six `pyrelisk_ventrock` up the arm, one `pyrelisk_neckcore` at the collar. Every
one is a real creature row with hp and a shot radius, per the design constraint.

```lua
Creatures.items.pyrelisk_ventrock = {
    id = "pyrelisk_ventrock", name = "Magma Bleeder", rarity = "Boss",
    archetype = "krakenpolyp",           -- the shipped no-op: it is a rock
    health = 1100,
    waters = "volcano",
    shotRadius = 6.0,                    -- ~12 studs across; the arm is 18 wide
    rewards = { coins = { 80, 140 }, xp = 240 },
    body = { model = "CreaturePack", species = "Pyrelisk", shape = "urchin",
             scale = 0.8, color = ..., markColor = Color3.fromRGB(255, 120, 20) },
}

Creatures.items.pyrelisk_neckcore = {
    id = "pyrelisk_neckcore", name = "The Ashfall Core", rarity = "Boss",
    archetype = "krakenpolyp",
    health = 9000,
    waters = "volcano",
    shotRadius = 11.0,                   -- SUPERSEDED 2026-09-12: shipped as 13.0
                                         -- (measured 13.40 at the relocated collar
                                         -- site, rounded down). See the handoff 6c.
    rewards = { coins = { 400, 620 }, xp = 1100 },
    body = { model = "CreaturePack", species = "Pyrelisk", shape = "urchin",
             scale = 1.6, color = ..., markColor = Color3.fromRGB(255, 200, 60) },
}
```

**Where they stand, and why not `parts.mounts`.** The rocks must sit on the
*drawn* arm, whose position is a function of the fallen pose and of which flank
survived. `parts.at = "mounts"` cannot express "mirrored by flank" and would put
the whole set on the wrong side half the time — the exact failure the arena's
nine monoliths already suffered once ("all nine `stones` were mirrored", the
checklist's first trap).

> **SUPERSEDED 2026-09-12 — see Addendum V (act 3, the arm climb, is CUT).**
> `PyreliskPath.armRocks` and `.neckCorePoint` were built, shipped and then
> **DELETED** by the mesh lane when the climb was cut; nothing on the server
> places a rock or a core. Text kept frozen as the record of what existed.

So they are placed from the path module, which is the file's own rule
("Server and client both require this file, and that is the point"):

```lua
-- New in PyreliskPath, and it is the ONE new public function the module needs:
-- six points along the planted arm's bone chain, alternating +/- 5 studs
-- laterally so the route weaves rather than running straight up the middle.
function PyreliskPath.armRocks(state, side: number): { Vector3 }
    -- t = 0.12, 0.28, 0.44, 0.60, 0.74, 0.88 of (fist -> wrist -> elbow ->
    -- shoulder), each lifted BONE_LIFT + 3.0 along that bone's own up so the
    -- rock stands ON the walking face rather than inside it.
end

-- ...and the neck collar, body-local, one point.
function PyreliskPath.neckCorePoint(state): Vector3
    -- PY_RIG.neck (8.0, 0.0, 152.0) taken through bodyCFrame, lifted 6 studs
    -- along the body's own up.
end
```

`Fn.pyreliskPlantRocks(creature, def, now)` spawns seven creatures at those
points with `partOf = creature`, exactly as `Fn.plantKrakenArm` (L14505) does the
single-part form of `Fn.spawnBossParts`. `healthMult` is inherited off
`creature.extra` the same way (L13710).

**Breaking one:** `Fn.pyreliskChip(creature, def, K.PY_ROCK_FRACTION)` — 0.05 —
and a permanent lava pool at the rock's own point (a `ventbreath`-shaped pool
with `duration = math.huge`, cleaned up by the collapse). The route narrows as
you climb it, which is the same idea the arms use in act 2 and the pillars use
in act 4, and it is the only reward structure a fight with no punish window can
offer (the Kraken's `polypStep` comment makes the same argument).

**Breaking the neck core** is the colossus's death: `Fn.pyreliskChip(creature,
def, 1.0, { lethal = true })` drops health to 0, `CreatureService.damage`'s
zero-health branch calls `beginBossCollapse` (L1793), and §4.5 takes over.

### 4.4 Hazards while climbing

| hazard | where it comes from | cadence |
|---|---|---|
| the three back vents fire | `PyreliskPath.VENTS`, the shipped sites; a `mark` telegraph then a pool on the deck | every 6.0s, one vent at a time, never the one a player is nearest at the tell (it is a hazard, not a gotcha) |
| `crownshed` | a NEW attack row, act-3 pool only. The head shakes and slabs of crown fall down the *arm*, along its axis | `cooldown = 9.0`, `arm = 1.6` of warning, `radius = 14` |
| `ashfall` | the shipped row, unchanged. The summit is still shedding | its own 19.0s cooldown |
| `ventbreath` | the shipped row, aimed along the ramp | its own 17.0s cooldown |
| the lava | `Fn.pyreliskLavaWatch`, unchanged | falling off is the punishment, and the rescue exists |

`crownshed` is the one new attack row in the whole design, it reuses the `mark`
telegraph branch, and its handler is `barrage`-shaped — the same shape `ashfall`
already is, with the landing points taken along the ramp instead of under the
party. It exists because act 3's other three hazards are all *area* hazards on a
wide arena, and the climb needs one that reads as aimed at the route.

**The colossus does not attack with its arms in act 3.** It has none. The body's
only remaining moves are the ones the head and the summit make, which is exactly
the three rows above.

### 4.5 The drop

`beginBossCollapse` (L7586) already has the branch this needs — the
`def.succeededBy` branch the Wrack added, which takes the death, holds it open
for `wreckFor` seconds while an attribute ramps 0 → 1, and hands the real death
back to `kill()`. Pyrelisk gets the same field under its own name:

```lua
-- Bosses.items.pyrelisk
succeededBy = "pyrelisk_heart",
collapseFor = 4.0,            -- the Wrack's `wreckFor`, one boss over
```

Over those four seconds:

* `ATTR.PY_ACT` goes to 4. The client eases the fallen pose down into the lake
  off it (the `WRACK_WRECK` idiom exactly).
* The seven rocks and both arms are taken with the boss by the shipped rule
  (L1456-1463: "a boss with a parts ring takes its surviving parts down with it").
* At t = 2.5s, `Fn.pyreliskOpenCaldera(def)` writes **`PyreliskCaldera = 1`** on
  the arena model. The lava lake drains, the lake floor goes, and a 120-stud
  shaft is open where it was.
* At t = 4.0s, `kill()` runs. `BossService.onKilled` sees `succeededBy` and
  calls `handoff` (L733), which raises `pyrelisk_heart` in the heart arena,
  carries `healthMult` across, re-points `fight.bossId`, re-arms the reaper's
  grace, and returns before the heart, the coins, the banner or the ride home.
  `suppressDrops` is already true for a boss carrying `succeededBy` (L334).

Then the party jumps in, which is §4.6. **Fall damage is not a thing in this
project** — there is no fall-damage system anywhere in `src/` — so "fall damage
off" needs no code. What the design owes instead is that nothing in the shaft
can kill them and that they cannot get stuck at the bottom of it.

### 4.6 Getting in

`Fn.pyreliskShaftWatch(def, now)` — a 0.5s poll, started when `PyreliskCaldera`
goes to 1 and torn down when the fight ends. Any participant whose root is
inside `r < K.PY_SHAFT_R (100)` of the arena centre **and** below
`K.PY_SHAFT_TRIGGER_Y` (the arena's rim world Y +292, minus 70 — i.e. 70 studs
down the shaft) is moved into the heart arena.

This is `Fn.pyreliskLavaWatch`'s shape exactly: the same per-player poll, the
same "is this player inside the lake's circle and below a height" test. It is
that function with a different answer.

**The move is `CreatureService.ArenaMove`, with one new optional argument:**

```lua
CreatureService.ArenaMove:Fire(def.islandId, "pyrelisk_heart", player?)
```

`BossService`'s listener (L954) gains a third parameter: given a player, it
moves only that player (to `ring[1]`, or the pad); given nil, it moves the whole
party, byte-identically to today. Six lines, backward-compatible, and it is the
only wire change in the design. Flag F-6.

**Why per-player and not the Kraken's whole-party swallow.** The directive's beat
is "you have to like jump in" — a yank makes the jump a cutscene. But nobody may
be stranded on a summit whose boss has left, so:

> **The grace.** `K.PY_SHAFT_GRACE = 30.0` seconds after the caldera opens, any
> participant still on the rim is pulled in with a party-form `ArenaMove:Fire(islandId,
> "pyrelisk_heart")`. That is the Kraken's swallow, used as the backstop rather
> than as the beat.

`BossService.fightCenter` (L223) reads `ATTR.FIGHT_CENTER` off the *live* boss's
model. `Fn.pyreliskOpenCaldera` writes the heart arena's floor position into
`FIGHT_CENTER` on the colossus before it dies, and `handoff` raises the heart
there, so neither the abandon reaper nor `sendHome` ever measures presence
against a summit the party has left. This is the exact silent failure
`fightCenter`'s comment documents.

---

## 5. The arm you climb — the geometry

The directive says "flat and easy to climb". **Today's route is not.**
`PyreliskPath.climbSlabs`' own measurements (L1185-1200):

```
rim path -> Hand tip      step 2.9
Hand                      ramp 31 deg
Forearm                   ramp 53 deg
UpperArm                  ramp 66 deg
Shoulder bridge           ramp  7 deg
Spine                     ramp 34 deg
```

and the file is explicit that this is forced: *"a shoulder 112 studs up whose
fist has to reach r 188 has 86 studs of horizontal run to spend on 118 studs of
drop, so the mean slope of the whole arm is 53 degrees before anything is
posed."*

The premise is right and the conclusion is the pose. A colossus that has been
stunned, lost both arms and gone prostrate does not have a shoulder 112 studs
up.

### 5.1 The target

| property | target | why |
|---|---|---|
| slope | **≤ 20°** | the brief's number. Roblox's `Humanoid.MaxSlopeAngle` defaults to 89°, so anything under that is *walkable*; 20° is where walking stops costing speed and a panic strafe does not slide. |
| width | **≥ 10 studs**; the design ships **18** | `PyreliskPath.WALK_ARM_SIZE.Z` is already 18.0. No change. 18 is wide enough to strafe a `crownshed` mark on. |
| step | **≤ 2.0 studs** | Roblox's automatic step-up is ~2 studs (`HipHeight`); anything at or under it is not felt. Today's worst step is 2.9. |
| gap | **none over 4.0 studs** | the brief allows 6. 4 is tighter on purpose: the player is being shot at, and a gap you must *notice* to clear is a death they cannot own. |

### 5.2 The `fallen` pose's arithmetic

From `PY_RIG` (boss_gen L2697): shoulder at boss-local `(-2.0, ±84.0, 126.0)`,
bones `upper_arm 58.0`, `forearm 64.0`, `hand 28.0` — total reach **150 studs**.
The lateral offset (84) is the shoulder's distance off the body axis.

The colossus goes to its knees and pitches forward. Let the fallen pose put the
working shoulder at **height y = 40** (from 125.3 on today's plant) and leave its
lateral offset at r 84. Lay the arm nearly straight down the radius:

```
fist lands at   r 195,  y 2.5        (inside PY_CLEAR_R 200 — open sky; outside
                                      PY_LAKE_R 120 — not in its own lava)
shoulder at     r  84,  y 40.0
horizontal run  195 - 84 = 111 studs
rise            40.0 - 2.5 = 37.5 studs
slope           atan(37.5 / 111) = 18.7 degrees          ✓ under 20
chain length    sqrt(111^2 + 37.5^2) = 117 studs of 150 available
                -> 33 studs of slack, taken as a gentle elbow and a wrist that
                   lies flat on the path rather than a straight rigid bar
```

Then shoulder → neck. `PY_RIG.neck` is `(8.0, 0.0, 152.0)` body-local; in the
fallen pose the neck collar lands at **y 58**, and the run from the working
shoulder pad to it is **52 studs**:

```
rise   58 - 40 = 18 studs
slope  atan(18 / 52) = 19.1 degrees                      ✓ under 20
```

So the whole route, rim path to neck core, is two ramps at 18.7° and 19.1° with
one 18-stud-wide surface throughout and the existing overrun-by-a-plate-width
rule closing the joints.

`PyreliskPath.BONE_LIFT` and `climbSlabs` need no structural change — the
`Shoulder` bridge and `Spine` ramp are re-solved against the fallen pose's deck
heights exactly as they are today against the plant's, and the neck collar
becomes a third named plate (`Neck`) at the top.

### 5.3 Flags on this section

* **F-7. Every number in §5.2 is derived, not measured.** They come from
  `PY_RIG`'s stated bone lengths and the shoulder offset, through a pose that
  does not exist yet. The file's own law is *"a number derived from a constant is
  a CLAIM; a number measured off the built objects is EVIDENCE"* (boss_gen
  L3930). Slice 2 exists to turn these into evidence: build the `fallen` pose,
  print the joint positions in the HANDOFF, and re-run
  `scratchpad/floor_check.py` against the climb route — which the checklist
  already owes ("Re-run `floor_check.py` against the **climb route** once the
  slabs are placed").
* **F-8. y = 40 for the shoulder is a choice, and it sets the drama.** Lower and
  the slope gets flatter but the colossus reads as lying down rather than
  kneeling; higher and 20° is missed. 40 is the largest value that clears 20° at
  a fist radius the arena allows.
* **F-9. The fist at r 195 is 5 studs inside `PY_CLEAR_R`.** The lip undercuts
  back to r 205, so a fist at 195 is under open sky by 5 studs. Verify against
  the export: if the undercut has moved, the fist moves with it and the slope
  re-derives.

---

## 6. Act 4 — the heart

### 6.1 The room

A **new arena**, built on the `KrakenGullet` template — a standalone interior
authored about its own origin with `z = 0` as the FLOOR datum, not the
waterline. New glb `assets/arena_pyrelisk_heart.glb`, model prefix
`PyreliskHeart_*`.

```lua
-- src/Shared/Config/BossArenas.luau, a new key. KEYED OFF AN ISLAND THAT DOES
-- NOT EXIST, exactly as `maelstrom_gullet` is: `BossArenaService.init` walks
-- this table by key and looks the key up in `Bosses.byIsland` for a roam radius
-- and a pose; "pyrelisk_heart" misses both and takes the default 36 /
-- no-profile branch, which is right for a room whose geometry is authored.
pyrelisk_heart = {
    islandId = "pyrelisk_heart",
    center = Vector3.new(-20000, 0, 13000),   -- F-10: verify nothing is here
    model = "PyreliskHeart",
    meshBottom = 584.0,      -- F-11: the gullet's lift, re-derived off the export
    floorRadius = 96,
    palette = {
        floor  = Color3.fromRGB(43, 39, 43),   -- cooled basalt, PY_BASALT
        rim    = Color3.fromRGB(23, 23, 31),   -- obsidian, PY_OBSIDIAN
        socket = Color3.fromRGB(120, 46, 20),
    },
    sockets = { --[[ 8 pillar feet, r 44-70, staggered bearings ]] },
    spawnPad = { offset = Vector3.new(0, 2.0, 74.0), radius = 11.0 },
    barrier  = { radius = 94, height = 30 },
}
```

**LIFTED 600 STUDS, for the gullet's reason and not by analogy**: the ocean is a
solid slab whose top face is `World.WATER_Y` and nothing carves under an arena,
so a room at sea level would be filled to the brim — which is precisely what
`verifyWaterline` exists to shout about.

Room shape (loose, per the coordinator's constraint 4 — the geometry lane owns
this):

* r 96 playable, floor out to r 108 so there is no crack at the wall foot.
  Smaller than the gullet's 118 because this is a shooting gallery with cover,
  not an open dish.
* Eight **obsidian pillars** on authored socket collars, r 44–70, bearings
  staggered so no two are on the same line from the entry pad — the sponson rule
  the Wrack's casemates are built on, applied to cover instead of to occlusion:
  the pillars are what you hide behind from the wall vents.
* The **heart** on a dais in the middle: a molten mass, the colossus's own
  `Pyrelisk_Core` material and the `PY_MAGMA` palette, Neon.
* Six **wall vents** at r 92, at three different heights (y 14 / 26 / 38), each
  a `PyreliskHeart_Vent` glow object. These are the shooters.
* The **landing floor**: the entry pad at `(0, 2.0, 74)`, which is where the
  shaft drops you and the heart is 74 studs dead ahead. `ringPositions` reads
  `spawnPad` for this key the same way it does for the gullet.
* The room has **no sky and no sun** — it needs the arena lighting override the
  gullet's HANDOFF already warns about.

### 6.2 The fight

```lua
Bosses.items.pyrelisk_heart = {
    id = "pyrelisk_heart",
    name = "The Ashfall Heart",
    shortName = "The Heart",
    creature = "pyrelisk_heart",
    islandId = "volcano",          -- the SAME island: this is the volcano's
                                   -- boss, and BossService's fight record,
                                   -- participants and ride home all key off it.
    -- ONE Pyrelisk across four acts, so the heart is his:
    heartAs = "pyrelisk",
    arena = { offset = Vector3.new(0, 0, 0), radius = 96 },
    aggro = 140,
    standoff = 200,   -- unreachable on purpose: it is a heart on a dais
    speed = 0,
    turnRate = math.rad(40),
    hitRadius = 26,
    submerge = 0, riseDepth = 0, riseTime = 2.0,
    attackGapMin = 1.2, attackGapMax = 2.2,
    enrageBelow = 0.25, enrageCooldownMult = 0.55, enrageDamageMult = 1.35,
    stances = 1,

    parts = {
        row = "pyrelisk_pillar",
        count = 8,
        at = "sockets",            -- the arena's authored collars
        -- NO `regrow`. A broken pillar is broken.
    },

    phases = {
        { below = 1.0,  attacks = { "ventspit", "heartpulse", "magmarain" } },
        { below = 0.45, attacks = { "ventspit", "heartpulse", "magmarain", "ventbarrage" } },
    },
    attacks = { --[[ §6.3 ]] },
}
```

`Creatures.items.pyrelisk_heart` carries `vulnerableWhen = "partsDown"` — the
shipped declarative gate (`Fn.unaimable`, L842-848). The heart cannot be
scratched while a pillar stands; the eighth pillar's death stamps `ATTR.EXPOSED`
through `kill()`'s existing path (L1404-1455) and the heart's bar is the only
thing left in the room.

```lua
Creatures.items.pyrelisk_heart = {
    id = "pyrelisk_heart", name = "The Ashfall Heart", rarity = "Boss",
    archetype = "boss", boss = "pyrelisk_heart", waters = "volcano",
    vulnerableWhen = "partsDown",
    health = 14000,
    rewards = { coins = { 5000, 7500 }, xp = 6000 },
    drops = { materials = { magma_core = { 3, 5 }, obsidian_shard = { 6, 9 },
                            ember = { 10, 16 }, sulfur = { 6, 9 } } },
    body = { model = "CreaturePack", species = "Pyrelisk", shape = "urchin",
             stance = "upright", scale = 2.0, ... },
}

Creatures.items.pyrelisk_pillar = {
    id = "pyrelisk_pillar", name = "Obsidian Pillar", rarity = "Boss",
    archetype = "krakenpolyp",      -- the shipped no-op; a pillar does not walk
    health = 1500,
    waters = "volcano",
    rangedOnly = false,             -- they stand on the floor; melee reaches
    shotRadius = 7.0,
    rewards = { coins = { 120, 200 }, xp = 300 },
    body = { model = "CreaturePack", species = "Pyrelisk", shape = "urchin",
             scale = 1.1, color = PY_OBSIDIAN-ish, markColor = magma },
}
```

**What breaking one does** — three things, and they are the room's whole reward
structure:

1. It drops the heart's shield by one eighth. Eight down = the heart is open.
   This is `partsAlive` and it is free.
2. It **vents lava at its own socket**, permanently: a pool of `radius = 16` with
   `duration = math.huge`, the `ventbreath.pool` shape. Eight pools at r 44–70
   is most of the room's middle band by the end, which is the whole design of
   the room: your cover and your floor are the same eight objects, and killing
   one spends both.
3. It **steps the vents' cadence** by `K.PY_PILLAR_STEP = 0.90`, once per pillar
   — `0.90^8 = 0.43` of the opening pace by the eighth. This is the Kraken's
   `machine.polypStep = 0.86` idiom, by name and by number's-worth: *"the room
   gets louder as it gets shorter, which is the only reward structure a boss
   with no punish window can offer."*

### 6.3 "Getting shot at by something"

**Six wall vents throwing globs, and it is zero new projectile code.**

`Fn.throwGlob(creature, def, p, landing, flight, now, event, drawKind, extras, origin)`
(L2934) takes an **arbitrary origin** as its last argument — the Kraken's
`inkmortar` already passes "the hand that threw it". So:

```lua
K.ATTACK_HANDLERS.ventspit = {
    fire = function(creature, def, p, now, root, player, dist)
        -- Pick `p.count` of the six wall vents, weighted AWAY from the vent
        -- that fired last, so the room's pressure rotates round the wall.
        for _, vent in Fn.pyreliskHeartVents(creature, p.count) do
            local at = Fn.markedGround(creature, def, p, root)
            Fn.throwGlob(creature, def, p, at, p.flight, now,
                         "strikeHit", "spit", { skin = "lava" }, vent)
        end
    end,
}
```

`Fn.pyreliskHeartVents` reads six authored offsets off the new BossArenas row
(`vents = { Vector3, ... }`, the `sockets` convention in three dimensions) and
resolves them against the arena centre. That is the entire shooter.

> **ProjectileService is not available in this room, and the reason is worth
> stating because it is the kind of thing someone reaches for and then debugs.**
> `ProjectileService.emit` hardcodes the volley's flight plane as
> `batch.y = World.WATER_Y + FLIGHT_Y` (L1072). Every ball in every volley flies
> flat at the waterline. The heart's room is 600 studs up and the Ashfall Throne
> is 292 studs up, so the Wrack's bullet-hell engine would fire its walls through
> the sea under both arenas, invisibly, hitting nobody. Making it usable is a
> one-line change (`p.flightY or World.WATER_Y + FLIGHT_Y`) plus the same field
> on the client contract, and it is **out of scope** for this design. Flag F-12.

The heart's book:

| move | what it is | numbers |
|---|---|---|
| `ventspit` | 2–4 wall vents throw globs at marked ground. `tell = "mark"`. | `count = 3`, `flight = 1.6`, `radius = 15`, `damage = { 44, 62 }`, `cooldown = 4.5` |
| `heartpulse` | the heart beats: an expanding ring from the dais. `tell = "ringTell"`. The metronome the pillars tighten. | `radius = 84`, `inner = 26`, `damage = { 38, 54 }`, `cooldown = 7.0 × 0.90^pillarsDown` |
| `magmarain` | `pattern = "everyone"` marks, the shipped `ashfall` shape | `extra = 2`, `spread = 26`, `arm = 1.4`, `radius = 13`, `damage = { 48, 66 }`, `cooldown = 13.0` |
| `ventbarrage` | phase 2 only: all six vents at once, one glob each, no aim — a wall you walk out of | `count = 6`, `spread = 40`, `flight = 2.0`, `cooldown = 16.0` |

Every `tell` above names a real `CreatureEventController.EVENTS.telegraph` branch
that already exists (`mark`, `ringTell`). **No client telegraph branch is added
by this design** — which matters, because `CreatureEventController` is at the
Luau local limit with `CreatureService`.

### 6.4 What ends the fight

The heart's death. `BossService.onKilled` pays out under `heartAs = "pyrelisk"`,
so the win mints `Heart_pyrelisk` — the id `Bosses.items.kraken.gate.hearts`
already names (L3600). Without `heartAs` it would mint `Heart_pyrelisk_heart`
and the Kraken's gate would silently never open for anyone who beat this fight.

The ride home: `sendHome` measures against `fightCenter`, which reads
`ATTR.FIGHT_CENTER` off the live boss. The heart's gimmick `onKill` clears it and
fires `ArenaMove:Fire("volcano", "volcano")` to put the party back on the summit
before `RETURN_DELAY` — the `krakenheart` gimmick's shape, at L15657-15671.

**The heart drop** stays on the `pyrelisk_heart` creature row (above): the
volcano band's four materials at roughly 1.5× the colossus's old table, because
this is now the payout for four acts. The colossus's own `drops` block moves to
the heart row and `Creatures.items.pyrelisk` keeps only the health bar, since
`suppressDrops` is true for a boss carrying `succeededBy` anyway.

---

## 7. THE ATTRIBUTE CONTRACT

Per the coordinator's constraint 5, byte-identically, before anyone writes.
Everything here is a LEVEL held for as long as it is true, never an edge.

### 7.1 New, on the COLOSSUS model (`pyrelisk`)

| name | type | range | writer | readers | nil means |
|---|---|---|---|---|---|
| `PyreliskAct` | number | `1` \| `2` \| `3` \| `4` — and `4` is published on the HEART's model, not this one (§7.3) | CreatureService (`Fn.pyreliskPublishAct`) | PyreliskBodyController, BossHudController, CameraController | act 1 |
| `PyreliskArmL` | number | `0..1` | CreatureService, every frame in act 2 | PyreliskBodyController, BossHudController | the arm is not a creature (act 1, or act 3+) — **NOT the same as 0** |
| `PyreliskArmR` | number | `0..1` | as above | as above | as above |
| `PyreliskRocks` | number | integer BITMASK, bits 0..5 | CreatureService, on plant and on each death | PyreliskBodyController | no rocks planted; disambiguate with `PyreliskAct` |
| `PyreliskCore` | number | `0..1` | CreatureService, every frame in act 3 | PyreliskBodyController, BossHudController | the neck core is not planted |

> **SUPERSEDED 2026-09-12 — see Addendum V (act 3, the arm climb, is CUT).**
> In the table above, the `PyreliskRocks` and `PyreliskCore` rows are GONE —
> removed from `CreatureService`, written by nothing, read as "absent" by a
> client that needs no change for it. `PyreliskAct`'s range is now **1 / 2 / 3**
> (shell / arms / heart), the colossus carrying 1-2 and the heart 3 via
> `K.PY_ACT_HEART`; the act-3+ parentheses in the `PyreliskArmL/R` rows now mean
> "the collapse", which is where act 2 ends. Addendum V has the full delta.

`ATTR.PY_ACT = "PyreliskAct"`, `ATTR.PY_ARM_L = "PyreliskArmL"`,
`ATTR.PY_ARM_R = "PyreliskArmR"`, `ATTR.PY_ROCKS = "PyreliskRocks"`,
`ATTR.PY_CORE = "PyreliskCore"`.

`PyreliskRocks` bit `(i-1)` is `PyreliskPath.armRocks(state, side)[i]`, in that
table's authored order — the `SeamsOpen` / `WRACK_HATCHES` bitmask convention,
and the same warning applies: **the count is load-bearing.** Six rocks, six bits.
A seventh entry in `armRocks` with no bit behind it is the failure mode a bitmask
has.

### 7.2 New, on the ARENA model (`Workspace.BossArenas.PyreliskArena`)

| name | type | range | writer | readers | nil means |
|---|---|---|---|---|---|
| `PyreliskCaldera` | number | `0` \| `1` | CreatureService (`Fn.pyreliskOpenCaldera`) | BossArenaService (the geometry swap), WeatherController / the client VFX lane | `0` — the lake is a lake |

Monotonic within one fight; reset to `0` when the fight ends (`removeOwnedParts`
and the abandon reaper both reach it).

**Why the attribute and not a function call.** `BossArenaService` requires
nothing from `CreatureService` (its five requires are BossArenas, Bosses,
BrinejawPath, MeshColors, World), so `CreatureService` *could* require it — but
`CreatureService` is at the Luau 200-local limit and a new file-scope `local` is
forbidden. An attribute on a replicated `Workspace` instance costs no local, is
level-triggered, replicates to late joiners for free, and is readable by the
client VFX lane without a second wire. `Fn.pyreliskOpenCaldera` finds the model
by name (`Workspace:FindFirstChild("BossArenas")` → `PyreliskArena`) inside the
function body; `BossArenaService.init` connects
`GetAttributeChangedSignal("PyreliskCaldera")` on it after `placeAuthored`.

### 7.3 New, on the HEART model (`pyrelisk_heart`)

**RE-FROZEN in v2.** The first draft reused `ATTR.PHASE_INDEX` with the value 3.
The verification the runtime lane owed came back negative — see §7.5 — so it
does not.

| name | type | range | writer | readers | nil means |
|---|---|---|---|---|---|
| `PyreliskAct` | number | always `4` on this model | CreatureService | BossHudController, the client VFX lane (no bespoke heart controller — heart creature rides the standard CreaturePack pipeline; molten mass is arena geometry under the Glow rule) | not the heart |
| `PyreliskPillars` | number | integer BITMASK, bits 0..7 | CreatureService, on plant and on each death | the client lane, BossHudController | no pillars planted |

`ATTR.PY_ACT` is the **same attribute name as §7.1**, carrying values 1–4 across
two models: 1–3 on the colossus, 4 on the heart. One name, one meaning ("which
act of the Pyrelisk fight is this model drawing"), monotonic across the whole
fight even though the model underneath it changes at the handoff. That is
strictly better than the reuse it replaces, and it costs one fewer `ATTR` field
than the first draft did.

`ATTR.PY_PILLARS = "PyreliskPillars"`. Bit `(i-1)` is
`BossArenas.items.pyrelisk_heart.sockets[i]`, in that table's authored order —
the `SeamsOpen` / `WRACK_HATCHES` convention, and the count is load-bearing the
same way: eight sockets, eight bits.

`Exposed` is the shipped `partsDown` stamp and is not redefined.

`ATTR.PHASE_INDEX` is **not written on any Pyrelisk model.**

### 7.5 The `PhaseIndex` verification (owed, done, negative)

Grepped `PHASE_INDEX` / `PhaseIndex` across `src/Client` and `src/Shared`. Four
hits, one of which attaches meaning to the value 3:

| site | what it does |
|---|---|
| `KrakenBodyController.luau:22` | contract comment: `PhaseIndex (1..3)` |
| `KrakenBodyController.luau:839` | `state.phase = tonumber(model:GetAttribute("PhaseIndex")) or 1` |
| **`KrakenBodyController.luau:864`** | **`frame.visible = state.phase ~= GULLET_PHASE`**, with `GULLET_PHASE = 3` at L177 |
| `KrakenIntro.luau:149` | seeds a cutscene stand-in with `PhaseIndex = 1` |
| `BossHudController.luau:427` | does NOT read the attribute; recomputes `bossPhaseIndex` locally |

**So the value 3 is not a plain discriminant.** It carries one specific
instruction — *"do not draw the Kraken's body"* — and L175-177 says so in as
many words: "PHASE 3 IS A DIFFERENT PLACE… the head and the limbs do not exist
in there."

The reuse would in fact have been *harmless in practice*, and it is worth
writing down why the design rejects it anyway: `adoptBoss` (L604) refuses any
model whose `Pose ~= "kraken"`, so a `pyrelisk_heart` model never enters that
controller and L864 is unreachable for it. But that safety comes from a **pose
gate in a neighbouring lane's file**, not from the attribute meaning nothing —
which is exactly the shape of dependency this project's contracts exist to
refuse. An attribute whose value means "hide the Kraken" cannot also mean "this
is the Pyrelisk's fourth act" on the strength of a guard somewhere else
continuing to hold.

Per the coordinator's instruction: the heart gets its own attribute, and §7.3 is
re-frozen above.

### 7.4 Reused unchanged — do NOT fork any of these

`SeamsOpen`, `SeamsBroken`, `SeamMeterL`, `SeamMeterR` (L6620-6623, and their
contract block in PyreliskBodyController L95-134 stays true byte for byte);
`Planted` (L6611 — it already means "which flank is the ramp"); `Stance` /
`Stances` (L6540/6545); `Exposed` (L134); `Slump`, `FaceAngle`, `Attack`,
`AttackBlend`, `Strike`, `AimAngle`, `AimSide`, `Lean`, `Rise`, `PoseCenter`,
`Pose`; `FightCenter` (L319); `Health` / `MaxHealth`; `Weakpoint` / `WeakpointHot`.

**Seam 1, the chest, is finally spent.** The contract reserves it: *"Seam 1 is
the CHEST. It belongs to NEITHER meter and stays closed until phase 3 — the
server simply never sets bit 0 before then."* This design sets bit 0 in
`SeamsOpen` for the whole of act 3 (the chest gapes once the body is prostrate —
it is the door the caldera drop is justified by) and sets it in `SeamsBroken`
when the neck core dies. The client's three-state vocabulary
(CLOSED/OPEN/BROKEN) already covers it and needs no branch.

---

## 8. IMPLEMENTATION

### 8.0 Ownership and sequencing

Per the coordinator: the mesh/rig lane owns `boss_gen.py`, `arena_gen.py`,
`PyreliskPath.luau`, `PyreliskBodyController.luau`, `BossHudController.luau`. The
runtime lane owns `CreatureService.luau` handlers + the phase machine,
`Bosses.luau`, `Creatures.luau`, `BossArenas.luau`, `BossService.luau`,
`BossArenaService.luau`. `Remotes` is whoever needs the first new one — and
**nothing in this design needs a new Remote.**

**The floater fix lands first**, on the body as it is, and this redesign builds
on the fixed body. The torso-connectivity / posed-contact / uniformity work
currently in flight in `assets/boss_gen.py`'s Pyrelisk section is slice 1, and
slice 2 does not start until it is exported and green.

Worktree-only pending the consolidation commit, per the shared-checkout rules:
**`CreatureService.luau`** and **`CreatureEventController.luau`** (both at the
Luau 200-local limit). Every addition to either must be a field on `ATTR`, `K`
or `Fn` — **zero new top-level locals**, and `luau-compile -O0` (gate five) is
the only check that sees a violation. Never `git add` either file while another
session is editing it.

### 8.1 Files: new vs edited

| file | new/edit | lane | what |
|---|---|---|---|
| `assets/boss_gen.py` | edit | mesh | the floater fix; then 3 new objects (§8.3) |
| `assets/arena_gen.py` | edit | mesh | split `_Base`; 2 new objects; the whole `build_pyrelisk_heart` builder |
| `assets/arena_pyrelisk_heart.glb` | **new** | mesh | the heart room |
| `assets/bundle_gen.py` | edit | mesh | one row: `("arena_pyrelisk_heart.glb", "PyreliskHeart")` |
| `assets/bundles/MANIFEST.json` | regen | mesh | |
| `src/Shared/Config/MeshColors.luau` | regen | mesh | `python3 tools/gen_mesh_colors.py` |
| `tools/gen_mesh_colors.py` | edit | mesh | add `pyrelisk_heart` to its `ARENAS` list (L58) |
| `src/Shared/Modules/PyreliskPath.luau` | edit | mesh | the `fallen` pose; `armRocks`; `neckCorePoint`; `climbSlabs` re-solve |
| `src/Client/Controllers/PyreliskBodyController.luau` | edit | mesh | the `fallen` draw; the five new attributes; chest seam bit 0 |
| `src/Client/Controllers/BossHudController.luau` | edit | mesh | arm bars, rock pips, core bar, pillar pips |
| `src/Client/Controllers/CameraController.luau` | edit | mesh | a `PYRELISK_HEART_ARENAS` entry beside `KRAKEN_GULLET_ARENAS` (L95) |
| `src/Client/Controllers/WeatherController.luau` | edit | mesh | an `ARENA_MOOD_BOUNDS` entry for the heart room and a **mood of its own**. This is the other half of the lighting override §6.1 cites off the gullet's HANDOFF ("the room has NO sky and NO sun — it needs an arena lighting override or the Neon veins are all the player gets"). The Ashfall Throne's `summit` mood was tuned at density 0.30 against open sky at 292 studs up; a sealed room 600 studs up wants the opposite treatment, and taking the summit's bounds by default would leave the heart lit like a mountain top. Unset, the room is not merely dim — it inherits whatever mood the player's last arena left, which is the silent-absence shape. |
| `src/Shared/Data/Creatures.luau` | edit | runtime | 5 new rows; `pyrelisk`'s drops move |
| `src/Shared/Data/Bosses.luau` | edit | runtime | the `pyrelisk` row's rework; the new `pyrelisk_heart` row |
| `src/Shared/Config/BossArenas.luau` | edit | runtime | the new `pyrelisk_heart` key; `volcano` gains `vents` |
| `src/Server/Services/CreatureService.luau` | edit | runtime | **worktree-only**; §8.2 |
| `src/Server/Services/BossService.luau` | edit | runtime | the per-player `ArenaMove` argument |
| `src/Server/Services/BossArenaService.luau` | edit | runtime | the `PyreliskCaldera` geometry swap |
| `docs/import-checklist.md` | edit | mesh | row 7o's object count; a new row for the heart arena |
| `docs/pyrelisk-fight-checklist.md` | edit | either | rewrite against the new fight |

### 8.2 CreatureService — the checklist, with anchors

Everything below is a field on `ATTR`, `K` or `Fn`. **No new top-level locals.**

**Remove**
- [ ] `Fn.pyreliskVentSwing` (L7131) and its `Remotes.RequestAttack.OnServerEvent` connection (L7182).
- [ ] `pyreliskSwingAt` (L6896) — *this is a top-level local, and removing it BUYS one back.*
- [ ] `K.PY_VENT_REACH`, `K.PY_VENT_HITS`, `K.PY_VENT_FRACTION`, `K.PY_SWING_GAP` (L6876-6880).
- [ ] The three local requires at L6886-6888 (`InventoryService`, `Equipment`, `Weapons`) if nothing else reads them — **three more top-level locals back**. Audit before deleting.

**New `ATTR` fields** — `PY_ACT`, `PY_ARM_L`, `PY_ARM_R`, `PY_ROCKS`, `PY_CORE`, `PY_PILLARS`, `PY_CALDERA` (§7).

**New `K` constants**, beside the existing `K.PY_*` block at L6846:
`PY_FLANK_FRACTION = 0.15`, `PY_ARM_FRACTION = 0.20`, `PY_ROCK_FRACTION = 0.05`,
`PY_ARM_WINDOW = 120.0`, `PY_ARM_POOL_GAP = 7.0`, `PY_ARM_POOL_R = 55.0`,
`PY_SHAFT_R = 100.0`, `PY_SHAFT_DROP = 70.0`, `PY_SHAFT_GRACE = 30.0`,
`PY_PILLAR_STEP = 0.90`, `PY_HEART_ARENA = "pyrelisk_heart"`.
`K.PY_SEAM_METER_HP` 2600 → 5400 (L996).

**New `Fn` helpers**
- [ ] `Fn.partyMult(creature)` — `(creature.extra and creature.extra.healthMult) or 1`. Generic; two other call sites could use it.
> **SUPERSEDED 2026-09-12 — see Addendum V (act 3, the arm climb, is CUT).**
> Three lines in this checklist describe act 3 and are dead:
> `Fn.pyreliskArmsDone` is **not** act 3's entry any more — it is the fight's
> ENDING (the second arm's death takes the body down through `damage()`, the
> same route the neck core used) and it sets no `state.planted`;
> `Fn.pyreliskPlantRocks` is **deleted**; and `Fn.pyreliskPublishAct` writes
> **one** attribute, not five. Everything else on the list stands.

- [ ] `Fn.pyreliskChip(creature, def, fraction, opts?)` — the one new primitive.
- [ ] `Fn.pyreliskBothFlanksBroken(state)` — `state.seamsBroken` has both masks.
- [ ] `Fn.pyreliskDropArms(creature, def, now)` — act 2's entry.
- [ ] `Fn.pyreliskArmsDone(creature, def, now)` — act 3's entry; sets `state.planted`, plants the rocks.
- [ ] `Fn.pyreliskPlantRocks(creature, def, now)` — seven part-creatures off `PyreliskPath.armRocks` / `neckCorePoint`.
- [ ] `Fn.pyreliskPublishAct(creature, act)` — the five attributes, in one place.
- [ ] `Fn.pyreliskOpenCaldera(def)` — writes `PyreliskCaldera = 1` on the arena model.
- [ ] `Fn.pyreliskShaftWatch(creature, def, now)` — the per-player drop, off `Fn.pyreliskLavaWatch`'s shape.
- [ ] `Fn.updatePyreliskArm(creature, dt, now)` — the pool clock.
- [ ] `Fn.pyreliskHeartVents(creature, count)` — pick wall vents.

**Edits at named anchors**
- [ ] L1142 `Fn.pyreliskSeamCredit` — divide by `K.PY_SEAM_METER_HP * Fn.partyMult(creature)`.
- [ ] L1148 — on a full meter, credit the chip instead of setting `seamBreakSide` alone.
- [ ] L9949 `pyreliskLatch` — prefer the unscarred flank.
- [ ] L9900/L9903 `handfall` — `Fn.openStagger` calls go; `p.seamCredit` lands instead via `Fn.spendStone`'s return.
- [ ] L7040 `Fn.updatePyreliskMount` — the gate gains `or creature.pyreliskAct == 3`.
- [ ] L16063 — the seam cash-out becomes the act-2 gate (§2.2).
- [ ] L16082 — the stance line is UNTOUCHED; the thresholds move in `Bosses.luau`.
- [ ] L16106 the `stagger` branch — act 2 runs here for 120 seconds; add the "arms dead → act 3" exit.
- [ ] L16733-16787 `ARCHETYPE_UPDATERS` — add `pyreliskarm = Fn.updatePyreliskArm`.
- [ ] `K.GIMMICKS` — a `pyreliskheart` gimmick beside `krakenheart` (L15657) for the ride home.
- [ ] `Fn.krakenSwallow`'s `ArenaMove:Fire` (L15577) — unchanged; the new third argument is optional.

### 8.3 New mesh objects

**`assets/boss_gen.py` — three new objects, taking the pack from 14 to 17.**
The 14-object contract is versioned deliberately or not at all (constraint 2), so
here is the FINAL set, exactly:

```
Pyrelisk_Core      Pyrelisk_Torso     Pyrelisk_Head      Pyrelisk_Jaw
Pyrelisk_Crown     Pyrelisk_Eyes      Pyrelisk_Shoulder  Pyrelisk_UpperArm
Pyrelisk_Forearm   Pyrelisk_Hand      Pyrelisk_Seam      Pyrelisk_Vent
Pyrelisk_WalkArm   Pyrelisk_WalkDeck
Pyrelisk_ArmRock   Pyrelisk_NeckCore  Pyrelisk_WalkNeck        <- NEW
```

| object | purpose | collidable? | notes |
|---|---|---|---|
| `Pyrelisk_ArmRock` | the "orange rock" MODULE, instanced six times up the arm | no (shell) | authored at the origin with **+Z outward**, `rotation_euler = (0, radians(-90), 0)`, the `Pyrelisk_Seam` / `_Vent` convention. ~11 studs across, a magma boil in a basalt collar. Its glow must stand PROUD of the mass (`build_kg_heart_glow`'s lesson). `PY_COMPONENTS["ArmRock"] = 1`. |
| `Pyrelisk_NeckCore` | the big rock at the collar | no (shell) | one object, not a module; ~22 studs, sited at `PY_RIG["neck"]`. `PY_COMPONENTS["NeckCore"] = 1`. |
| `Pyrelisk_WalkNeck` | the walking plate from the shoulder pad to the neck collar | **YES** | the third `_Walk*` object. 52 studs long × 18 wide × 4 thick, seated off the measured neck-band rock top by `_py_seat_*`'s pattern. |

New HANDOFF lines: six `ARMROCK %d at (…) ROBLOX rel (…)`, one `NECKCORE at (…)`,
one `WALKNECK` line with the measured neck rock top and the seated z. Plus the
`fallen` pose's joints printed as evidence (the F-7 fix): `FALLEN shoulder /
elbow / wrist / fist (y, r) and the resulting slope in degrees`.

**`assets/arena_gen.py` — the caldera splits, and a new room.**

Today `build_py_base` (L4113) is one dead-flat disc across the whole caldera plus
a 40-stud cone skirt — **the floor is continuous under the lava and there is no
cavity.** So:

| object | new/edit | collidable? | notes |
|---|---|---|---|
| `PyreliskArena_Base` | edit | yes | becomes an ANNULUS: rings from r 118 outward. The centre disc leaves. |
| `PyreliskArena_LakeFloor` | **new** | yes | the r 0–120 disc that closes the hole. This is what holds a player standing in the lava today, and it is what `PyreliskCaldera = 1` switches off. |
| `PyreliskArena_Lava` | edit | no (HAZARD_MARKERS), queryable | unchanged geometry; it goes transparent with the lake floor |
| `PyreliskArena_Shaft` | **new** | yes | a tube r 108 from z 0 down to z −120, walls only, no floor. Needs **PreciseConvexDecomposition** or a hull fills it solid — the same note `KrakenGullet_Walls` carries. |

> **Do not sink the lava.** The lake must stay flush (the checklist's second
> trap). The shaft is *under* a removable floor, not a pit in the lake.

And `build_pyrelisk_heart` — the whole new builder, on the `build_kraken_gullet`
template (§6.1). Objects: `PyreliskHeart_Base`, `_Walls`, `_Dais`, `_Heart`,
`_HeartGlow`, `_EntryPad`, `_Socket1..8`, `_Vent1..6`, `_VeinGlow`, `_RubbleDeco`.
Register in `ARENAS` (L6046), `CAMERAS` (L6222 — **every camera must stand INSIDE
the dome or the frame renders black**), `PREVIEW_PROPS` (L6035, with its own
point lights: the room has no sun), `SCENE` (L6292).

### 8.4 Studio import consequences

- **Row 7o changes from "14 objects" to "17 objects, exact names."** Three new
  names; `Pyrelisk_WalkNeck` joins `_WalkArm` / `_WalkDeck` as the only
  collidable parts (box fidelity, exact and correct); `Pyrelisk_ArmRock` and
  `Pyrelisk_NeckCore` want **Neon** alongside `_Core`, `_Seam`, `_Eyes`.
- **`PyreliskArena` gains two objects** (`_LakeFloor`, `_Shaft`).
  `PyreliskArena_Rim` still needs **PreciseConvexDecomposition** (row 7n, already
  owed), and `_Shaft` needs it too.
- **A new import row for `arena_pyrelisk_heart.glb`** → `PyreliskHeart`:
  PreciseConvexDecomposition on `_Walls` and `_Base`; default hull fine for
  `_Dais`, `_EntryPad`, `_Socket1..8`, `_Heart`; `_HeartGlow`, `_VeinGlow` and
  `_Vent1..6` carry "Glow" and go Neon; `_RubbleDeco` loses collision and query.
- **`tools/studio_import.lua`** picks the new files up if they are added to its
  list; otherwise the count it reports goes stale.
- **`python3 tools/gen_mesh_colors.py` must run after every one of these**, or
  the new objects arrive at the importer's default grey and
  `placeAuthored`'s uncoloured warning fires (L487-498).

### 8.5 The slices

Each ends playable. Each names its gates. Five gates = `check_content`,
`check_floaters`, `gen_mesh_colors` (clean regen), `luau-compile -O0`,
`stylua --check`.

---

#### **Slice 1 — the floater fix, on the body as it is**

Mesh lane, already in flight. `assets/boss_gen.py` Pyrelisk section only: torso
connectivity, the posed-contact assertion, uniformity. No runtime change.

*Ends playable:* exactly today's fight, on a body with nothing floating.
*Gates:* all five. `check_floaters` is the one that matters.
*Playtest must confirm:* the vent spikes and the throat cluster are attached in
the exported glb, and `_py_knit_selftest` / `PY_COMPONENTS` still pass.

**Nothing after this slice starts until it is exported and green.**

---

#### **Slice 2 — the `fallen` pose and the shallow climb**

> **SUPERSEDED 2026-09-12 — see Addendum V (act 3, the arm climb, is CUT).**
> `armRocks` and `neckCorePoint` were later deleted with the climb. The `fallen`
> track and `climbSlabs` **stay**: the fallen pose is now the COLLAPSE (act 2
> holds it and she continues down through the opening caldera), and `climbSlabs`
> / `rampCFrame` remain live for act 1's bait-`handfall` plant window, handing
> back nothing once the body is fallen.

`PyreliskPath.luau` gains the `fallen` keyframe track, `armRocks`,
`neckCorePoint`, and `climbSlabs` re-solved against it (the `Neck` plate joins
`Hand` / `Forearm` / `UpperArm` / `Shoulder` / `Spine` / `Deck*`).
`PyreliskBodyController` draws it. `boss_gen.py` gains `Pyrelisk_WalkNeck` and
prints the fallen pose's joints in the HANDOFF.

Reachable in-game only by an admin command (`adminPose("pyrelisk", "fallen")`),
so the shipped fight is untouched.

*Ends playable:* today's fight; plus a pose you can stand the boss in and walk up.
*Gates:* all five.
Also in this slice, because everything downstream depends on them:
- **F-14's hard pin** — `bearing` / `breath` / `lean` frozen on
  `state.planted ~= 0 OR state.act >= 2`. It must exist before act 2 does.
- **F-4's regeneration** — the fallen HANDOFF's fist positions per flank, which
  are what slice 3 plants the arms from. The DEAD VALUES in §3.2 are never pasted.

*Playtest must confirm:* **the slope, measured.** Run `scratchpad/floor_check.py`
against the climb route and confirm ≤ 20° on both ramps, 18 studs of width, no
step over 2.0 and no gap over 4.0. **This slice is where F-4, F-7, F-8, F-9 and
F-14 are resolved; every later number is re-derived from what it measures.**

---

#### **Slice 3 — act 1 into act 2: the seams, the stun, the arms**

Runtime lane. `Fn.pyreliskChip`, `Fn.partyMult`, the seam meter's scaling and
its new HP, the flank chips, `Fn.pyreliskDropArms`, the `pyrelisk_arm` row and
its `pyreliskarm` updater, the `parts` block, the 0.70 / 0.30 thresholds,
`handfall`'s `seamCredit`, the scarred-flank latch, `PyreliskAct` 1 and 2,
`PyreliskArmL` / `PyreliskArmR`, the transition-gated chip
(`Fn.pyreliskFlankPaid`) and the re-cycle latch (`creature.pyreliskArmsOut`).

**The four-equality `check_content.py` gate (§9.3, F-13) lands in THIS slice**,
not later: it is what makes the 0.70 / 0.30 thresholds safe to re-tune, and
every number it guards is authored here.

*Ends playable:* acts 1 and 2 in full. The second arm's death chips to 0.30 and
the fight continues into the old act-3 book (`ashfall` / `ventbreath` /
`shardhurl`) until the colossus's bar runs out through the seams, dying as today.
Nobody climbs anything yet.
*Gates:* all five. **`luau-compile -O0` is the one that catches a new top-level
local**, and this slice both adds and removes several.
*Playtest must confirm:* both flank meters fill in a sane time solo and in a
four-party; the arms land ON the rim path and are shootable AND swingable; the
120-second window feels long but not dead; **the failure branch pins health at
exactly 0.70 across repeated cycles** — watch the bar over three failed windows;
a bar that walks down is the chip double-firing, which is CHANGE 2's whole
subject — and returns to act 1 without clearing `SeamsBroken`; **re-entry costs
one meter, not two**; after a failed window the boss casts `ventbreath` /
`ashfall` and never an attack with no handler (CHANGE 1's whole subject); a
client that joins mid-act-2 draws two arms with correct bars.

---

> **SUPERSEDED 2026-09-12 — see Addendum V (act 3, the arm climb, is CUT).**
> This whole slice was built, gated, landed — and then removed. See Addendum V.

#### **Slice 4 — act 3: the climb**

Runtime + mesh. `Fn.pyreliskArmsDone`, `Fn.pyreliskPlantRocks`, the
`pyrelisk_ventrock` / `pyrelisk_neckcore` rows, the mount gate's `act == 3`,
the vent-swing retirement, the `crownshed` row and handler, the vent hazards,
`PyreliskRocks` / `PyreliskCore`, chest seam bit 0. `boss_gen.py` gains
`Pyrelisk_ArmRock` and `Pyrelisk_NeckCore`.

*Ends playable:* acts 1–3. The neck core's death kills the colossus and the
fight pays out as today (`succeededBy` not yet set, so `onKilled` takes the
normal path and mints `Heart_pyrelisk`).
*Gates:* all five, plus `gen_mesh_colors` regen for the two new object names.
*Playtest must confirm:* the route is climbable under fire, in both directions;
all six rocks are reachable and shootable from the arm without falling; the
lava rescue still catches a fall; the colossus stays frozen for the whole act
(if it turns, the rocks teleport — §3.2); killing the core reads as the ending.

---

#### **Slice 5 — the caldera opens**

`arena_gen.py`'s `_Base` split and the two new objects; the
`PyreliskCaldera` attribute; `BossArenaService`'s listener and geometry swap;
`collapseFor = 4.0` and `Fn.pyreliskOpenCaldera` in `beginBossCollapse`;
`Fn.pyreliskShaftWatch`; `BossService`'s per-player `ArenaMove` argument.

The shaft's target for this slice is **`"volcano"`** — jumping in drops you back
on the rim path with a banner. Observable, inert, and it proves the whole
transport without the room existing.

*Ends playable:* acts 1–3, then the lake drains, the shaft opens, you jump in and
land back on the rim. The fight pays out as in slice 4.
*Gates:* all five, plus the arena import.
*Playtest must confirm:* the lake floor and lava vanish together and the shaft is
under them; nobody falls through the caldera before `PyreliskCaldera = 1`;
the shaft's walls hold (PreciseConvexDecomposition applied); the drop reads as a
fall; the 30-second grace pulls a straggler; `verifyWaterline` and `verifyGround`
stay silent.

---

#### **Slice 6 — act 4: the heart**

`build_pyrelisk_heart` and `arena_pyrelisk_heart.glb`; the `pyrelisk_heart`
`BossArenas` key; the `pyrelisk_heart` `Bosses` row and its four attacks; the
`pyrelisk_heart` and `pyrelisk_pillar` `Creatures` rows; `succeededBy` /
`heartAs`; the pillar pools and `polypStep`; the wall-vent glob throwers; the
`pyreliskheart` gimmick's ride home; `CameraController`'s arena entry;
**`WeatherController`'s `ARENA_MOOD_BOUNDS` entry and the heart room's own
mood**, paired with the arena lighting override; `PyreliskAct = 4` and
`PyreliskPillars` on the heart model (**not** `PhaseIndex` — §7.5);
`bundle_gen` / MANIFEST / MeshColors / import-checklist.

*Ends playable:* the whole fight, summon to `Heart_pyrelisk`.
*Gates:* all five.
*Playtest must confirm:* the party lands on the entry pad facing the heart;
all eight pillars are reachable and the room is still walkable after eight
permanent pools; the wall vents hit from six real points and not from the room's
centre; the heart is untouchable until the eighth pillar and obviously open
after; the win mints **`Heart_pyrelisk`** and not `Heart_pyrelisk_heart` (check
the Kraken's gate); the ride home puts everyone back on the summit; the abandon
reaper does not fire on a party 40,000 studs from where the colossus rose;
**the room is lit by its own mood and not by whichever arena the player was in
last** — walk in from the summit and from a fresh join, and confirm both look
the same.

---

## 9. HP, the party, and the flags

### 9.1 What a party of 1–4 fights

`BossService.raise` scales by party size at summon and rides the factor in on
`extra.healthMult` (fixed at summon; a mid-fight rescale is the leave-and-shrink
exploit the file's header warns about). That factor reaches:

| thing | scaled today? | scaled after? |
|---|---|---|
| the colossus's own bar | yes | yes — **but it is never damaged directly.** It is a progress dial driven by `Fn.pyreliskChip`, so scaling it is inert. Say so on the row. |
| the two arms, seven rocks, eight pillars | n/a | **yes**, free, via `Fn.spawnBossParts`' `healthMult` (L13710) and the single-part plant |
| the flank seam meters | **no** | **yes** — F-1, the one real gap |
| the heart | n/a | yes, carried across by `handoff` (L742-752) |

### 9.2 Total damage the party must deal

| act | thing | per | count | subtotal |
|---|---|---|---|---|
| 1 | flank seam meters | 5,400 | 2 | 10,800 |
| 2 | arms | 7,000 | 2 | 14,000 |
| 3 | vent rocks | 1,100 | 6 | 6,600 |
| 3 | neck core | 9,000 | 1 | 9,000 |
| 4 | pillars | 1,500 | 8 | 12,000 |
| 4 | the heart | 14,000 | 1 | 14,000 |
| | | | **total** | **66,400** |

> **SUPERSEDED 2026-09-12 — see Addendum V.1.** The act-3 cut removed the six
> vent rocks (6,600) and the neck core (9,000), so the total is **50,800**, not
> 66,400, across three acts. The table above is kept as the record of what was
> priced. F-2 and F-3 are **re-derived, untuned**.

Today's fight is 40,000, of which only the window's worth is ever reachable.
66,400 across four acts with damage legal in three of them is the intent, and it
is the single biggest number in this design that nobody has measured. **Flag F-2.**

`Creatures.items.pyrelisk.health` stays **40,000** as the dial's denominator,
with a comment saying it is a denominator and not a bar.

### 9.3 The flags — every place this design depends on a number I could not verify

| # | the claim | why it is unverified | **owner** | resolved in |
|---|---|---|---|---|
| **F-1** | the seam meters are not party-scaled today | read off L1142; no scaling term is present | **runtime lane** | slice 3 |
| **F-2** | ~~66,400~~ → **50,800** total (RE-DERIVED 2026-09-12, Addendum V.1), 5,400 per flank meter, every HP number above | the checklist says "TTK and party scaling are untuned… nothing here has been measured against a real party." Band-4 sustained DPS is unknown. **Re-derived, UNTUNED — playtest decides.** No row was retuned for the act-3 cut. | **runtime lane** | a measured playtest, now across acts 1/2/3 |
| **F-3** | 120s stun cap | one decision with the arms' 7,000 HP; derived from a guessed DPS. **Now the fight's ONLY timed gate and only wall** (the act it used to hand off to is gone), so the pair is load-bearing in a way it was not when this was written. **Re-derived, UNTUNED — playtest decides.** | **runtime lane** | a playtest, with F-2, together |
| **F-4** | the two `parts.mounts` triples | DEAD VALUES (§3.2). Derived from a pose that does not exist; superseded outright by the `armJoints` plant | **mesh lane** (regenerates them in slice 2 alongside F-7/8/9) | slice 2 measures, slice 3 plants — or deletes the block |
| **F-5** | `shotRadius = 14` captures a 150-stud limb | it does not; option (a) fights the fist, option (b) generalises `hitHeight` to an axis | **ship (a) in slice 3**; the `hitAxis` follow-on is the **mesh/rig lane's** | slice 3, then a follow-on |
| **F-6** | `ArenaMove`'s third argument | a new wire shape, however small; BossService's listener is shared with the Kraken | **runtime lane** | slice 5 |
| **F-7** | the whole of §5.2 — 18.7°, 19.1°, y 40, r 195, 117 of 150 studs | derived from `PY_RIG`'s constants through an unbuilt pose. *A number derived from a constant is a CLAIM.* | **mesh lane** | **slice 2, `floor_check.py`-measured** |
| **F-8** | shoulder at y 40 | a drama-vs-slope choice, not a measurement | **mesh lane** | slice 2 |
| **F-9** | the fist at r 195, 5 studs inside `PY_CLEAR_R` | `PY_CLEAR_R = 200` and the undercut at r 205 are measured, but not against this pose | **mesh lane** | slice 2 |
| **F-10** | heart arena centre `(-20000, 0, 13000)` | off the 24,000 ring by design, inside `OCEAN_MIN_SPAN` ±32,600 — but not checked against the gullet at `(-20000, 0, -13000)` or anything else | **mesh lane** | slice 6 |
| **F-11** | `meshBottom = 584.0` | copied from the gullet. **`meshBottom` is a DECISION, not a measurement** — re-derive from `arena_gen`'s own HANDOFF after the first export. | **mesh lane** | slice 6 |
| **F-12** | ProjectileService is unusable in both arenas | read off L1072 (`batch.y = World.WATER_Y + FLIGHT_Y`). Confirmed by reading; the fix is one line but is out of scope. | unassigned | noted, not fixed |
| **F-13** | the 0.15 / 0.20 / 0.05 / 0.00 chips summing exactly to the thresholds AND to 1.0 | arithmetic, and it is exact — but it is *fragile*: change any chip and a stance change fires inside an act, silently. | **runtime lane** | the four-equality `check_content` gate below, landing with slice 3 |
| **F-14** | the colossus stays frozen for all of acts 2 and 3 | the mount layer enforces it today only for a 20-second window, and only while `planted ~= 0`. Act 2 has `planted == 0` and runs for 120 seconds. | **mesh/rig lane, STRUCTURALLY** — see below | slices 2 and 3 |

**F-14 gets a structural fix, not a playtest.** The design's most load-bearing
unstated assumption is that the body does not turn or breathe for the whole of
acts 2 and 3, and the shipped guarantee does not cover it: `PyreliskPath` drops
`breath` and `lean` and the mount pins `faceAngle` **only while `planted ~= 0`**,
which is false for all 120 seconds of act 2 (both arms are down; neither is the
ramp). A colossus that idles-watches through act 2 swings the drawn arms — and
therefore the two arm creatures resolved once against `yaw0` (§3.2) — out from
under themselves.

So the freeze is hard-pinned in `PyreliskPath` rather than asserted in a
playtest:

> `bearing`, `breath` and `lean` return their frozen values whenever
> **`state.planted ~= 0` OR `state.act >= 2`**.

`state.act` is `PyreliskAct` published back into the pose state by the existing
`publishPose` / `colossusState` round trip. One condition, one file, both sides
of the wire computing it from the same field — which is the whole reason the
path module is shared. The mesh/rig lane owns it and it lands in slice 2, before
anything depends on it.

**F-13 is worth a gate.** `tools/check_content.py` already reads one number out
of two files in two languages and fails on a mismatch (the Wrack battery's shot
radius). The same shape applies here — **four equalities, not three**, so that
the ledger is asserted to close rather than merely to line up with the
thresholds:

```python
# tools/check_content.py — the Pyrelisk chip ledger.
# Reads K.PY_*_FRACTION out of CreatureService.luau and phases[].below out of
# Bosses.luau, and fails on any mismatch. Without this, every failure is
# SILENT and presents as something else: a stance banner firing in the middle
# of the arms, or a colossus that will not die when its neck core does.
assert PY_FLANK_FRACTION * 2 == 1.0 - phases[2].below            # act 1: 0.30
assert PY_ARM_FRACTION   * 2 == phases[2].below - phases[3].below # act 2: 0.40
assert PY_ROCK_FRACTION  * 6 + PY_CORE_FRACTION == phases[3].below # act 3: 0.30
assert (PY_FLANK_FRACTION * 2 + PY_ARM_FRACTION * 2
        + PY_ROCK_FRACTION * 6 + PY_CORE_FRACTION) == 1.0          # the ledger closes
```

The fourth line is the one that matters, and adding it forces a design decision
the first draft left implicit: **the neck core's chip is a number
(`K.PY_CORE_FRACTION = 0.00`), not a special case.** §4.3 said the core kills the
colossus by dropping health to 0 with `{ lethal = true }` — which is true, and
is also why its ledger entry is zero: the six rocks already spend the whole of
act 3's 0.30, so the core's kill is `health <= 0` arriving on its own rather
than a chip. Writing it as an explicit 0.00 rather than omitting it is what lets
the fourth assertion be an equality instead of an inequality, and it is what
catches the day someone re-tunes the rocks to five and expects the core to make
up the difference.

Floating-point: compare to within 1e-9, and keep all five constants authored as
exact two-decimal values so the sum is representable.

## Appendix K — ArenaMove gotchas inherited from the Kraken gullet (from its lane, 2026-09-12)

Ordered as they bit them. Owner in brackets.
1. [71] `placeAuthored` centres `<Model>_Base` on the row's `center` — whichever object the heart export names `_Base` DEFINES where the arena stands. Check before writing the row.
2. [71] `PoseCenter` is re-published at the transition and must never be cached client-side; PyreliskBodyController must read it every frame or the heart teleport strands the rig at the caldera.
3. [18] `hitRadius` swaps with the move (kraken 280 → 30). The heart creature's capture sphere must be interior-sized or ranged selection eats every shot.
4. [71] `creature.anchor`/`creature.pos` move together; `FightCenter` publishes interior-phase only. Client gates rig-drawing on the act (PyreliskAct = 4), not on position, or the exterior rig draws inside the chamber.
5. [18] Participation on the move: key by userId (kraken used `extra.name` vs player.Name — rename-vulnerable, owed a cleanup).
6. [18] Victory recall is NOT BossService's: return-to-exterior rides a Creatures `gimmick` (krakenheart) firing collapse + recall; copy that pattern so RETURN_DELAY works untouched.
7. [18] BossService additive only, no reconstruction (parked beginFight/adminStart + ownerless party-scaling set). Build ON the ArenaMove listener; it assumes ONE move per fight — Pyrelisk moves once (rim → heart; the shaft is a fall, not a move). If that ever changes, extend the assumption explicitly.
8. [71, shared] Interior arenas have no lighting override (closed chamber, no sky/sun) — unresolved for the gullet; whatever the heart does (WeatherController mood + point lights per CHANGE 3), tell the Kraken lane.

## Addendum M — slice 2 measured FALLEN numbers (2026-09-12, Pyrelisk mesh lane, floor_check on built geometry)

All four acceptance criteria PASS. Worst ramp 19.00° (Forearm; Hand 18.41°, UpperArm 16.91°,
Shoulder 14.77°, Neck 13.93°); worst step 1.08 studs (boarding step off the rim 1.73); worst
gap 0.25; width 18 on every climb plate. Pack contract now 15 objects (`Pyrelisk_WalkNeck`
added; `_ArmRock`/`_NeckCore` still owed in slice 4 → 17 final).

**Correction to §5.2 by measurement (F-7):** the neck-band rock top is z 155.38, so the
WalkNeck collar end seats at z 160.0, not the 149.0 the doc solved against; the neck ramp is
13.93°, not the claimed 0.66°. Still under the 20° cap. The full FALLEN HANDOFF (shoulder /
elbow / wrist / fist y–r chain, six `armRocks` points, `neckCorePoint`, Roblox-relative) is
forwarded verbatim by the mesh lane and retires the two server warn-rails
(`Fn.pyreliskRampPoints` fallback, `neckCorePoint` fallback).

## Appendix N — as-built deltas (2026-09-12, server lane, slices 3/4/4b/4c/5/5b/6)

**The text above is FROZEN and has not been edited.** This appendix is the
complete list of places the shipped code deliberately differs from it. Nothing
below was silently adapted: each entry names the choice and why it was forced.
The commit-time landmark for each is in `docs/pyrelisk-fight-handoff.md` §1.

Read this before "fixing" any of it back to the frozen text — several of these
read as typos and are not.

### N.1 The updater signature is `(creature, now, dt)`, not `(creature, dt, now)`
§3.3 writes `Fn.updatePyreliskArm(creature, dt, now)`. The dispatcher calls
`updater(creature, now, dt)`. Written to the **dispatcher**. Taking the design's
order literally would have made `now` a frame delta — a pool clock that fires
every frame, presenting as *"the arms spam pools"*, not as a signature bug.
Shipped as `Fn.updatePyreliskArm(creature, now: number, _dt: number)`.

### N.2 `armfall` is dropped
The attack does not exist in the shipped book. The act-2 arms are planted as
creatures by `Fn.pyreliskDropArms` and reconciled off `creature.partsAlive`;
there is no move of that name and no handler for one.

### N.3 The chips ride the `SeamsBroken` **level**, not a `kill()` hook
§2.2 does not say which path `Fn.pyreliskChip` takes, and §1.1's table says
"first arm dies → 0.20" without saying where. Both are reconciled in the tick:

- **Flank chips** fire on the scar mask's 0→1 transition, tested as a level via
  `Fn.pyreliskBothFlanksBroken(state)` guarded by `creature.pyreliskFlanksPaid`
  (per side) and `creature.pyreliskArmsOut` (so a *retirement* can never be read
  as two kills). An edge test would let the arms return exactly once and never
  again, leaving a party that lost the first window with no route back into act 2
  at all. A level test means **either** meter re-filling returns the arms — one
  meter, not two, which is the right price for a retry.
- **Arm / rock / core chips** are reconciled off `partsAlive` in the tick rather
  than hooked into `kill()`'s `partOf` branch. Same information one frame later;
  cannot be missed by a death that took another route (a collapse taking its
  parts down, a pool tick landing the blow); and it keeps this fight's machinery
  out of the generic parts path.

**And the chips are NOT routed through `damage()`.** The precedent §2.2 cites
(`K.PY_VENT_FRACTION`) ran inside a stagger where `untargetable` is false. The
flank chips fire in act 1, where the colossus **is** untargetable and `damage()`
returns `nil` on its gate — every chip silently swallowed, presenting as *"the
boss's bar never moves"*. `Fn.pyreliskChip` writes the health line and
republishes `ATTR.HEALTH` directly, flooring at `K.PY_CHIP_FLOOR` so no chip can
enter the death path by arithmetic.

**Consequence (a latent bug, fixed in slice 4):** `creature.pyreliskArmsOut`
stays set through act 3, and act 3 plants seven more parts on the same
`partsAlive` counter. Without the `pyreliskAct == 2` clause the first rock to
break would have been read as an arm and chipped **0.20 instead of 0.05**,
walking the dial into the collapse four rocks early — and it would have looked
like *"the boss died too fast"*, not like a counter bug.

### N.4 `parts.mounts` is DELETED (F-4's preferred resolution)
The DEAD VALUES were never pasted, and `Bosses.items.pyrelisk.parts` carries no
`at` field at all. The arms are planted from
`PyreliskPath.armJoints(state, side).fist` via `Fn.pyreliskPlantArm`, on the
single-part `Fn.plantKrakenArm` shape. A second reason beyond F-4's:
`at = "mounts"` routes through `Fn.wrackMountPoint`, whose own comment says
*"`at = "mounts"` is Wrack's mode alone … so nothing else passes through here"*
— Pyrelisk arriving there would have put a second boss through a transform
written against one hull's sand convention.

### N.5 The act-3 ramp is a POSE, not an entity
§4.1 and the slice brief disagreed; §4.1 is what shipped. The dead arm's
**creature is gone** (it died). What remains is the drawn limb plus
`state.planted` + `PyreliskPath.rampCFrame` + the mount layer's climb slabs —
none of which has ever required the arm to be an entity; that is how a baited
`handfall` has always worked. Keeping a dead part alive-but-untargetable would
mean intercepting `kill()` for one boss's parts. **If the intent was "nothing
shootable must remain up there", that holds**: the arm creature is gone and the
body stays `untargetable` for all of act 3.

### N.6 `Fn.markedGround` does not exist → `Fn.pyreliskHeartGround`
§6.3's `ventspit` sketch calls `Fn.markedGround`. Nothing of that name is in the
file. Written as `Fn.pyreliskHeartGround(creature, p, root)` on the real
precedent (`krakenmortar`): scatter around the party's footing by `p.spread`,
then clamp inside `floorRadius - p.radius` — `pyreliskLatch`'s *"a glob that
lands past the wall is a glob nobody could have been standing under"* rule, in a
circle.

### N.7 §6.3's handler signature is wrong
It writes `fire = function(creature, def, p, now, root, player, dist)`. The
dispatcher passes `(creature, def, p, now, root)`. Written to the dispatcher.

### N.8 The cadence step applies to the WHOLE heart, not just `heartpulse`
§6.2's table puts `× 0.90^pillarsDown` on `heartpulse`'s cooldown alone; §6.1
says each pillar *"steps the vents' cadence"*, which is the opposite scope. Took
the **broader** reading — because that is what makes the room tighten rather
than one move. Implemented as one guarded term,
`creature.cooldowns[a.name] = now + a.p.cooldown * rage * (creature.cooldownStep or 1)`,
in `Fn.endBossAttack` — the only line in the project that writes a cooldown —
with `creature.cooldownStep = K.PY_PILLAR_STEP ^ down`, and `nil` on every other
creature in the game. Say the word if you want it narrowed to `heartpulse`.

### N.9 `hitRadius = 13`, not §6.2's 26
`Fn.updateBoss`'s first frame does
`creature.hitRadius = (def.hitRadius or 0) * (creature.row.body.scale or 1)`,
and the heart's `body.scale` is **2.0**. So 13 × 2.0 is the 26 §6.2 wanted;
writing 26 gives a **52**-stud capture sphere in a room of radius 96 whose
pillars stand at r 44–70, and ranged selection eats every shot aimed at the
pillars that are supposed to gate the heart (Appendix K item 3).

Unlike the Kraken — which mutates `creature.hitRadius` in place at the swallow
because it is the *same creature* changing rooms — Pyrelisk's `handoff` spawns a
**fresh** creature, so the swap is automatic and needs no code. **No second
mutation was added, and none should be.** If `body.scale` moves, this moves
with it; the row says so in place.

### N.10 `Fn.spawnBossParts` keys its socket list by `arenaKey`
Not in the design, and not in any slice brief — found during slice 6 and flagged
as a scope addition rather than quietly widened. `Fn.spawnBossParts` looked its
sockets up as `BossArenas.items[def.islandId]`. The heart's `islandId` is
`"volcano"` **by design** (§6.2), and `BossArenas.items.volcano` has no
`sockets`, so `offsets` came back nil and the plant fell through to the even-ring
branch, which reads `parts.ring`, which the heart's row does not carry either.
That is **arithmetic on nil out of `Fn.spawnBossParts`**: no pillars, and a heart
gated on `vulnerableWhen = "partsDown"` with no parts is a boss nothing can ever
make vulnerable. Shipped as `def.arenaKey or def.islandId` — the identical
expression, for the identical reason, that `BossService.arenaPosition` needed.
**Inert for every shipped boss**, none of which has an `arenaKey`.

(`arenaKey` itself is a field name this lane invented; the design names none.
§4.5 says `handoff` "raises `pyrelisk_heart` in the heart arena" and never says
how, and it cannot happen by itself — see the handoff record §1, BS2.)

### N.11 The act-3 book is `{ ashfall, ventbreath, crownshed, shardhurl }`
`handfall` and `rimsweep` were **pruned** from `phases[3]` (slice 4c, on the
coordinator's ruling). **It is a theatre decision before it is a balance one.**
Both arms came off in act 2 and one of them is the ramp the party is standing on;
a fist slamming the rim path, thrown by a body that visibly has no hands, is not
a hard move, it is the wrong animal. The fight spends two acts making the loss of
those arms the story, and casting them afterwards un-tells it.

The old rationale for keeping `handfall` in every phase — *"it is the ONLY route
to a punish window; drop it from a phase and that stretch becomes unwinnable"* —
**is dead, and the row now says so** rather than just dropping it. It was true
until the redesign took `stagger` / `weakStagger` off the row and pointed the
bait at `seamCredit`. There is no window to open now, and act 3 has no meter left
to pay into: both flanks were scarred long ago.

**Order is load-bearing**, because `Fn.pickBossAttack` returns `attacks[1]`
whenever everything else is cooling or screened:

| slot | move | why it sits there |
|---|---|---|
| 1 | `ashfall` | the summit sheds. No aim, no limb, no target — the mountain being a mountain, so it cannot look wrong whenever it happens to fire. The right thing to fall back on. |
| 2 | `ventbreath` | still whole-body, but aimed and it takes path away, so it wants to be *chosen* rather than fallen back on. |
| 3 | `crownshed` | the act's aimed event, longest cooldown of the three. |
| 4 | `shardhurl` | see N.12. |

**`shardhurl`'s origin was the reason it nearly went too**, and it is now fixed
rather than pruned: the handler took its throw origin from
`PyreliskPath.fistPoint(state, state.aimSide)`, so in act 3 the rock left from a
hand that is not there — exactly the argument that pruned the other two. Shipped
with a **shoulder origin** gated on `(state.act or 1) >= 3`
(`PyreliskPath.armJoints(state, side).shoulder`; `armJoints` still reports it,
because a shoulder is a joint on the body, not on the arm). **Acts 1 and 2 are
byte-identical** — `state.act` is nil until `Fn.pyreliskPublishAct` writes it.

`crownshed` itself is thrown from `PyreliskPath.headCFrame(state)` — the crown —
on `shardhurl`'s shape with a different target set, and it deliberately **does
not** call `pyreliskLatch`: every other move latches an aim at the rim path, but
this one is aimed at the limb, which `state.planted` already committed. Latching
a bearing here would turn a body that has been frozen since act 2 and take the
ramp out from under whoever is standing on it. It is **act-3 only, and that is
DATA** — the row appears in `phases[3]` and nowhere else, so `Fn.pickBossAttack`
cannot draw it above 0.30. There is deliberately no act test in the handler: a
second gate is a second place to disagree.

### N.12 §4.4's underspecified numbers — the readings taken
1. **`crownshed` radius 14 on an 18-stud ramp is nearly full width.** Kept the
   design's number and made it fair through **placement**: `Fn.pyreliskRampPoints`
   **bands** the landings — one slab per third of the route, random within its own
   band — so three discs always leave 20+ studs of clear plate and **the dodge is
   along the arm, not across it**. A free scatter on the same axis can stack all
   three on one spot, which on an 18-wide ramp is a wall with a gap you cannot see
   from below. Nothing covers the route at once; this is not a sweep. **The radius
   is only fair while the banding holds** — widening one without the other is the
   regression, and the row's comment says so.
2. **§4.4 gives `crownshed` only `cooldown`, `arm` and `radius`.** The rest is
   filled from the book's own idiom, not invented: `windup = 1.6` (§4.4's `arm`,
   expressed as the field the shipped rows actually warn with), `duration` /
   `recover` 1.0 (the book's shortest — the move is a shake, not a swing),
   `count = 3` (`shardhurl`'s), `flight = 1.1`, `stagger = 0.3`, `spread = 4`
   (small on purpose: the lateral game belongs to `ventbreath` and the vents),
   `damage = { 58, 82 }` — between `ashfall`'s 54–76 and `handfall`'s 78–108,
   because it is aimed, so it costs more than a rain and less than a fist.
3. **The back-vent hazard is banded too.** `Fn.pyreliskVentHazard` ticks every
   frame inside act 3 (ambient, so it must run *between* attacks, which is most
   of the act), reusing `PyreliskPath.VENTS` and `ventPoint` whole — nothing new
   authored. `K.PY_VENT_GAP = 6.0`, `K.PY_VENT_ARM = 1.5`,
   `K.PY_VENT_POOL` **radius 11** — smaller than the arms' 13 and `ventbreath`'s
   15, *because a deck is the width of a corridor and a pool that took all of it
   is a wall*. It fires **never at the vent anybody is standing nearest**,
   measured across **every live player** rather than the aggro target: the party
   is spread up a limb, and the thing this must not do is fire under whoever
   happens to be aggro. Two-step (pending `mark`, then the pool), and the pool is
   owned by the **colossus**, so `beginBossCollapse` takes it down with the body
   and a fight that ends mid-climb leaves no burning ground on something that is
   no longer there.
4. **§4.4 does not say what happens when the nearest-vent rule leaves no
   candidate.** Conservative reading: **fire it anyway** rather than skip — a
   hazard that silently stops is worse than one that occasionally fires near
   somebody. Unreachable with three sites; guarded so a future one-site `VENTS`
   list still fires.

### N.13 `PyreliskShaftFloor` — a §7.2 contract addition, since RATIFIED
`ATTR.PY_SHAFT_FLOOR = "PyreliskShaftFloor"`, a **number**, on the arena model
beside `PyreliskCaldera`. §7 was frozen, so it was raised rather than assumed;
it has since been **ratified into §7.2** and is no longer pending.

| name | type | writer | readers | nil means |
|---|---|---|---|---|
| `PyreliskShaftFloor` | number | CreatureService, the colossus-side `Fn.pyreliskOpenCaldera` | **the server shaft watch only** — server-consumed, client-readable | *the caldera never opened this fight; the shaft test must not run* |

**Why it has to exist.** The depth half of the shaft test needs the arena's floor
plane. The only thing that knows it is the colossus (`state.center.Y`) — and the
colossus is destroyed 1.5 s after the caldera opens, while the creature that has
to keep watching the hole is the **heart**, in another room, which cannot ask it.
Nor is it derivable: `BossArenas.volcano.center.Y` is `0` and `meshBottom` is the
mesh's bbox, not the rim path. So it rides the one instance both can reach,
written once by the only thing that knows it.

**It is cleared as a PAIR with `PyreliskCaldera`** wherever that returns to 0 —
`Fn.pyreliskCloseCaldera` sets `PyreliskShaftFloor = nil` on the same two lines
that write `PyreliskCaldera = 0`, so the gimmick's close-then-recall and
`removeOwnedParts` both get it. That pairing is the contract: a floor plane left
behind after the hole closed is a shaft test running over solid rock.

### N.14 Two more places the design describes a mechanism that cannot do the job
Flagged rather than fixed; each needs a different lane's review.

- **"the scarred-flank latch prunes `phases[2]` to `ventbreath` / `ashfall`"**
  (§2.1, §3.1). `pyreliskLatch` picks `aimSide` — *which arm swings* — and
  nothing in it touches `Fn.pickBossAttack`'s pool. With both flanks scarred
  `Fn.pyreliskUnscarredSide` returns nil (by design: a hard gate there is the
  empty-pool bug), so after a failed window the boss still casts `handfall`,
  `rimsweep` and `shardhurl` from row 2, with whichever arm the geometry picks.
  Implemented as a **preference, not a gate**. Row 2 is still correct and still
  has no handler-less attack in it; only the comment's claim about *what* gets
  cast is aspirational. Making it true needs a pool filter.
- **The vent-swing minigame is RETIRED** (§8.2's "Remove" list, taken). Its four
  constants, `Fn.pyreliskVentSwing`, its second `Remotes.RequestAttack` listener
  and three requires (`InventoryService`, `Equipment`, `Weapons`) are gone, with
  a tombstone in place. That is what bought the top-level local count back from
  105 to **101** in a file at the Luau 200-local limit.

### N.15 Six files, not five — and one of them is untracked
§8.1's file table omits `src/Shared/Data/CreatureFamilies.luau`.
`tools/check_content.py` **fails** on any creature id with no family
(*"creature 'pyrelisk_arm' has no family in CreatureFamilies.byId (it would be
silent)"*), so every new creature row needs one: `pyrelisk_arm` as `leviathan`
(the family is a *sound* grouping, and the arm is the colossus's own body at
arena scale), and `pyrelisk_ventrock` / `_neckcore` / `_heart` / `_pillar` as
`elemental`. The gate is **two-directional**, so those rows and the `Creatures`
rows must land together.

**That file is `??` in git — untracked, not modified.** Some lane created the
whole thing and it has never been added, so it does not appear in `git diff HEAD`
at all. Anything that depends on it is green on this checkout and **red on a
fresh clone.**

### N.16 Every line number in §8.2 is stale, and was stale on arrival
All of these files moved during the build — `CreatureService.luau` gained ~10 KB
of Noctyss work mid-read, and `K.GIMMICKS.pyreliskheart` moved 49 lines during
the *audit* with no Pyrelisk edit in between. `Fn.pyreliskSeamCredit` was at
L1136, not §8.2's L1142; `BossService`'s `ArenaMove` listener is at L1033, not
L954. **Every anchor in the shipped work is an exact string for this reason**,
asserted `count == 1` before any write, and the commit-time record
(`docs/pyrelisk-fight-handoff.md`) identifies every hunk by **name, never by
offset**.

## Addendum O — slice 2 final (2026-09-12, mesh lane): zero adrift, F-9 resolved, seat numbers

Posed-connectivity gate (`tools/check_posed_connectivity.py`) exits 0 with ZERO adrift on the
15-object build; coverage spans all 15 objects with the three `_Walk*` slabs excluded by
documented design (welding them would close the seating clearance). Vents re-seated by
construction (feet through the deck slab into rock, `PY_VENT_DROP` 10.8; vent SITES unmoved).
Seat numbers fed into PyreliskPath: DECK1 145.6, DECK2 140.2, WalkNeck collar 159.8, vents
147.6 / 142.2 (each moved ≤ 0.4).

**F-9 RESOLVED by measurement** (rebuilt `tools/floor_check.py`): the lip overhang never reaches
inboard of r 229 on 24 bearings (arena HANDOFF agrees independently). §5.2's "undercut at r 205"
was stale; the fallen fist at r 192 clears by 32 studs, not 5.

### Appendix K additions — three geometry-instrument traps from the pass
9. `BVHTree.overlap` is BROAD PHASE (bounding boxes) — as a contact test it reports everything
   connected. Never use it for contact; use surface nearest-distance.
10. A weld's bite must GRAZE, not bury (0.06, not 0.55): `find_nearest` cannot tell inside from
    outside, so over-pulling makes the adrift count go UP while every weld reports success.
11. A pull must drop stale contact edges in BOTH directions, or the flood fill walks an edge
    that no longer exists.

## Addendum P — slice 2 FINAL (mesh lane): warn-rails retired, F-8 resolved, chord arm

`PyreliskPath.armRocks(state, side)` and `PyreliskPath.neckCorePoint(state)` are live, measured-fed.
Rocks (boss-local r / y): 179.49/5.40, 159.76/15.97, 146.47/23.78, 122.55/31.60, 113.06/46.41,
93.03/48.79; neck core r 45.99 / y 46.17; exactly six by construction. Fallen body: pitch 14°,
tilt ZERO by design (the act-2→3 boundary must not move the body under a standing party), sunk
105.2 into the lake; fist r 192.00. **F-8 resolved:** §5.2 measured slope off the BONE, not the
walking plate (plates ride 13–32.5 above their axes) — "right answer, wrong derivation".
**The arm lies ALONG A CHORD (72.8° of rim sweep), not down the radius** — every server
derivation uses the plate/rock points, never a radial line. Server notes adopted: FaceAngle is
not published once arms are down; `pyrelisk_neckcore.shotRadius` 11 is provisional until the
NeckCore rock is authored to straddle the collar (measured point is 7.2 above the head's
underside). Pack 15 objects; row 7o + both studio scripts updated.

**Sweep numbers (label before quoting):** fist→shoulder over the joint chain measures **46.62°**
(the safe quote today; reproduced by the server lane's stubbed-runtime harness); the rocks span
29.07°; the mesh lane's earlier "72.8°" was most likely the full walkable route end-to-end
(boarding tip → collar, including the shoulder→neck leg). The slice-4 HANDOFF will print all
three labeled off the built pose — replace this note with that set. Arm attack pools cluster at
the fist (act 2's fighting end); the upper limb is pool-free during the act-3 climb by design —
act 3's pressure is the vents and crownshed.

## Addendum Q — slice 4 mesh half (mesh lane, 2026-09-12): neck core relocated, pack FINAL at 17

**The frozen neck-core site was inside the skull**: at the authored (8, 0, 158) the point was
1.80 studs from the nearest head rock and only 25–33% ray-exposed from the top of the neck plate
(the one place act 3 is fought from); the skull's lower boulders reach 17–26 studs off the neck
axis at every bearing, so NO position on that axis works. Moved to `PyreliskPath.FALLEN_CORE_AT`
= authored (4, 18, 160), MIRRORED BY PLANTED FLANK — 64% exposed, 6.3 studs from the collar end
of the plate, straddles the collar. New generator gate `_py_expose_neck_core` fails any build
under 45% exposure. Addendum P's NECKCORE reading supersedes to **r 46.24 / y 49.08**, Roblox-rel
(42.6, 49.1, −18.0). No server position hunk (single source: `neckCorePoint`); Creatures
`pyrelisk_neckcore.shotRadius` 11.0 → **13.0** (measured effective 13.40). ArmRock module 11.0
across, boil 4.4 proud. Pack FINAL: 17 objects (`Pyrelisk_ArmRock`, `Pyrelisk_NeckCore` added;
both Neon by controller assertion). Row 7o + studio scripts 15 → 17. Labeled sweep numbers
follow in the mesh lane's final report.

## Addendum R — slice 4 FINAL (mesh lane): labelled sweep set, client landed

Labelled sweep numbers off the built pose (supersede every earlier sweep quote; the "72.8°"
reproduced by NEITHER measurement and is dropped from the record):
(a) bone chain shoulder-joint→fist **46.62°** (bearing 71.23° → 24.61°);
(b) walkable route boarding-tip→neck-collar **7.46° between endpoints but 60.01° of total
    bearing range** — non-monotonic in bearing (out the arm, back inboard across the pad, up the
    neck): endpoints nearly align while the middle swings wide;
(c) rocks first→last **29.07°**.
Gates: 17 objects exact, posed-connectivity zero adrift, digests identical, luau 0/0/0 + -O0.
Client landed: rocks/core drawn from the same `PyreliskPath.armRocks/neckCorePoint` calls the
server spawns from (nil ⇒ undrawn, 0 ⇒ dead crater / dead core, alive = hottest thing on the
body above any open seam's ceiling); HUD rows per act, individually presence-gated (a one-armed
colossus draws one bar); pillar pips staged dark until slice 6. Row 7o + studio scripts at 17;
bundle wiring requested from the bundle lane. Next mesh window: slice 6 (heart room, Weather /
Camera entries, the BossArenas placeholders' numbers).

## Addendum S — slice 6 mesh half (arena_gen released 2026-09-12)

`arena_pyrelisk.glb` 14 objects (+`_LakeFloor`, +`_Shaft`); `arena_pyrelisk_heart.glb` 22 objects.
Caldera equivalence probes at r 0/60/118/170/200 MATCH pre-split (cutscene lane's r-170 floorY
0.040 unchanged); meshBottom −84.7 unchanged; other seven arenas byte-identical by digest with a
positive control; check_floaters exit 0. Previews deliberately not re-rendered (nothing framed
moved). **NAMING DELTA vs §8.3:** the heart's six wall vents export as
`PyreliskHeart_Vent1Glow` … `Vent6Glow` (not `_Vent1..6`) — the Glow suffix is what makes
`placeAuthored` set Neon. Server-side verified INERT: no landed code string-matches heart object
names; `Fn.pyreliskHeartVents` reads authored offsets off the BossArenas row's `vents` list
(§6.3). MeshColors regen #2 (24 new rows: the two arena additions + 22 `PyreliskHeart_*`) runs on
the mesh lane's full CLEAR.

## Addendum T — slice 6 FULL CLEAR (mesh lane, 2026-09-12): measured heart row, one placement blocker

Placeholders in `BossArenas.pyrelisk_heart` filled with MEASURED values: meshBottom **586.0** (NOT
the gullet's 584 — the two rooms' bbox floors differ by 2; copying would have buried every height
the fight reads by 2 studs); spawnPad (0, 3.4, 74); sockets and vents as measured Roblox-relative
in the HANDOFF — **vent radii are PER-HEIGHT off the dome profile** (the design's flat r 92 put
vents 3 and 6 inside the wall, invisible and unshootable; caught by render inspection); volcano
caldera landing (0, −120, 0) arena-local; F-10 center kept after a collision survey. Heart room
22 objects final, PyreliskArena 14; renders `assets/arena_pyrelisk_heart_preview*.png`. Weather
mood + bounds, Camera PYRELISK_HEART_ARENAS entry, BodyController per-frame PoseCenter + act-4
gating all landed (Appendix K items 2, 4, 8).

**BLOCKER (server lane) — `BossArenaService.ringPositions` computes `center + pad.offset` with
center.Y = 0 and never adds a lifted room's lift**: a party ArenaMoved to the heart lands at world
Y 3.4 under a floor at ~600. `maelstrom_gullet` carries the same latent hole (sea-level rooms have
zero lift, which is why Tidebreak works). Fix lives in `ringPositions` itself — add the row's
lift (meshBottom − placed mesh bbox floor) on lifted arenas; both rooms come right together.
Landing as a slice-5 follow-up hunk (2026-09-12).

## Addendum U — plating remodel (mesh lane, 2026-09-12): fight contract held

Visual remodel (flush plating over a lava body) landed with the contract unchanged: 17 exact names,
digests identical, other six bosses byte-identical, posed-connectivity 0 adrift with control,
path-agrees green on all 7 seats, neck-core exposure 52% (floor 45%), worst fallen ramp 19.00°.
NO row changes: NeckCore effective radius 13.40 → 13.17 (shotRadius 13.0 stands); ArmRock
10.3×7.4; ventrock 6.0 stands. NO MeshColors regen needed (17 rows, no colour moved). PyreliskPath
re-keys: DECK z 149.9/140.9/139.7, VENTS z 151.9/142.9/141.7, FALLEN_COLLAR 159.9,
FALLEN_CORE_AT (4,16,162), WALK_ARM_LIFT 18.3, BONE_LIFT Forearm 18.3 / UpperArm 28.7. Bonus fix:
PyreliskBodyController's imported clones now get the bbox-centre offset (the recentring trap —
off-origin pieces would have drawn centred on their joint).

## Addendum V — ACT 3 (THE ARM CLIMB) IS CUT (2026-09-12, server lane)

The directive, verbatim: *"okay now the fallen rocks on its arm stuff maybe we can remove that
entire idea. maybe after the first phase it just goes straight into the volcano and we move into
that."* Sections 4, 5 and 7.1's rock/core rows are therefore **superseded** — kept in place as the
record of a mechanic that was built, gated and then removed, not as a description of the fight.

**The fight now.** Act 1, the shell: shoot the six seams, both flanks broken → the 120 s stagger,
both arms drop as `pyrelisk_arm` creatures. Act 2, the arms: kill both; **the second arm's death is
the hull's lethal chip** and the body collapses — `collapseFor` 4.0, `PyreliskCaldera = 1` +
`PyreliskShaftFloor` written at t 2.5, all unchanged — the party jumps into the shaft, per-player
`ArenaMove`, and the heart's room is entered exactly as §6 describes it. There is no third act on
the summit.

**Contract delta, ratified with the mesh lane before anything was written.** `PyreliskAct` is now
1 (shell) / 2 (arms) / 3 (heart), monotonic across the handoff, and the heart writes 3 —
parametrized as `K.PY_ACT_HEART` so the next renumber cannot leave a literal behind in a branch
nobody reaches until the fight's last minute. `ATTR.PY_ROCKS` and `ATTR.PY_CORE` are **removed and
nothing writes them**; §7.1's "nil means absent" clause is what makes that cost the client nothing,
and it did — `PyreliskBodyController` draws nothing and `BossHudController`'s "Rocks" pip row is
presence-gated and simply never appears. The chip ledger is two chips:
`K.PY_FLANK_FRACTION 0.15 × 2 + K.PY_ARM_FRACTION 0.35 × 2 = 1.00` (the arms absorbed the 0.30 the
six rocks used to spend). `stances` 3 → 2 with `phases` reduced to
`{ below = 1.0, … }, { below = 0.70, … }`; `bossPhaseIndex` → `ATTR.STANCE` is
`stances − (index − 1)`, so two rows give stance 2 at full health and stance 1 below 0.70, which is
what the banner should say. The act-3 attack book goes with the phase that was its only pool, and
`crownshed` — the one attack the whole redesign added — goes with it, row and handler.
`shardhurl`'s `act >= 3` crown-origin branch is deleted as unreachable; acts 1 and 2 are
byte-identical.

**The fallen pose is KEPT as the collapse** (mesh lane's call): act 2 already holds it, she
continues down through the opening caldera for `collapseFor`, and F-14's freeze stays keyed on
`planted ~= 0 OR act >= 2` — which is why **act 2 is held through the fall and no act 3 is ever
published on the colossus's model**. `ATTR.PLANTED` is never non-zero again after act 2, so
nothing re-enters the mount layer; the vent-smash minigame stays retired.

**The death is the neck core's route, line for line**, because that is the route the caldera hangs
off: the tick's arm reconciliation floors the dial at `K.PY_CHIP_FLOOR` (a chip may still never
enter the death path by arithmetic) and `Fn.pyreliskArmsDone` takes the body down with
`damage(…, { ignoreUntargetable = true })` on the same frame. Participant crediting is unchanged —
nil `deathBlow`, and the payout is the fight's participant set BossService built at summon.

**Removed server-side:** `Fn.pyreliskRampPlates`, `RampPoints`, `VentHazard`, `RockPoints`,
`CorePoint`, `PlantPart`, `PlantRocks`, `CoreBroken`; `K.ATTACK_HANDLERS.crownshed`; the tick's
act-3 reconciliation block; `K.PY_ROCK_FRACTION`, `PY_CORE_FRACTION`, `PY_ROCK_COUNT`,
`PY_ROCK_LIFT`, `PY_ROCK_WEAVE`, `PY_CORE_LIFT`, `PY_VENT_GAP`, `PY_VENT_ARM`, `PY_VENT_POOL`;
`Creatures.items.pyrelisk_ventrock` and `pyrelisk_neckcore` (131 → 129 rows) with their
`CreatureFamilies` rows. `PyreliskPath.armRocks` / `.neckCorePoint` / `.climbSlabs` /
`.rampCFrame` stay exported and **dormant**, and the pack stays 17 with `ArmRock` / `NeckCore` /
`WalkNeck` exported and undrawn — the mesh lane's decision, not a server concern. CreatureService's
top-level local count is **101 before and after**: every symbol touched is a field on
`ATTR` / `K` / `Fn`, never a file-scope `local`.

**§9.2's damage budget is now wrong** and is not re-derived here: the six rocks' 6,600 and the neck
core's 9,000 have left the fight, so the party's total is the colossus's dial plus two 7,000-HP arms
plus the heart's 14,000. Design flag F-2/F-3 (the unmeasured HP/DPS pair) now covers a shorter
fight than the one they were written against — re-derive the 120-second window and the arms'
health together, against the new total, before anyone calls this tuned.

**One thing the cut did not cause and does not fix — see the handoff's §7 BLOCKER list.**
`beginBossCollapse`'s first branch is gated on `def.succeededBy` alone, which is true of the
Pyrelisk (`pyrelisk_heart`) as well as of Admiral Wrack. The colossus therefore takes the *ship's*
wreck branch and `Fn.updateBossCollapse` returns before the pyrelisk branch runs: no collapse pose,
**no caldera, no shaft watch, nobody moved to the heart.** It has been true since slice 5b and it
is silent. The cut makes it the only remaining way the fight can end, so it now blocks the whole
act-4 entry. One-condition fix (`and not def.pose`, inert for the Admiral) is drafted and NOT
applied — it is the Wrack lane's hunk.

### Addendum V.1 — the re-derived damage budget (NOT retuned; no row moved)

Per the coordinator: the numbers below are **re-derived, not retuned.** Nothing
in `Creatures.luau` or `Bosses.luau` was changed for them. §9.2's table is
superseded by this one.

| act | thing | per | count | subtotal |
|---|---|---|---|---|
| 1 | flank seam meters (`K.PY_SEAM_METER_HP`) | 5,400 | 2 | 10,800 |
| 2 | arms (`pyrelisk_arm`) | 7,000 | 2 | 14,000 |
| 3 | pillars (`pyrelisk_pillar`) | 1,500 | 8 | 12,000 |
| 3 | the heart (`pyrelisk_heart`) | 14,000 | 1 | 14,000 |
| | | | **total** | **50,800** |

**66,400 → 50,800.** The climb took **15,600** with it — the six vent rocks'
6,600 and the neck core's 9,000 — which is **23.5% of the fight's whole damage
requirement**, removed in one edit. Nothing else moved: the flanks, the arms and
the heart's room are the numbers they always were.

**All four lines are party-scaled, and by one factor.** `extra.healthMult` is
set at summon and reaches every one of them: the arms through
`Fn.pyreliskPlantArm`, the pillars and the heart's own bar through
`Fn.spawnBossParts` / `spawn`'s `healthMult`, and the seam meters *inversely* —
`Fn.pyreliskSeamCredit` divides the damage by `K.PY_SEAM_METER_HP *
Fn.partyMult(creature)`. So the table reads **50,800 × the party factor** and
the per-head cost is flat, which is the property the seam divisor exists to
hold.

**`Creatures.items.pyrelisk.health` stays 40,000 and is still a DENOMINATOR,
not a bar** — it is the dial the two chips turn (0.15 × 2 + 0.35 × 2 = 1.00) and
it is not damage anybody deals. It does not belong in the table above and is not
in it.

**What actually changed about the SHAPE of the fight, and it is not only the
15,600.** The cut removed the act that carried the fight's only "hold this
position" beat, and it removed it from the middle: the party now goes seams →
arms → *a four-second fall* → a boss room. The 120-second window (`K.PY_ARM_WINDOW`)
is now the only timed gate in the whole fight, and the arms' 14,000 is the only
wall standing between act 1 and the heart's room. If the arms are too soft the
fight is three minutes long; if they are too hard the 120-second failure branch
(`Fn.pyreliskArmsFailed`) becomes the fight's main loop rather than its safety
net — and that branch was priced when there was an act 3 to reach.

**F-2 and F-3 are therefore RE-DERIVED, UNTUNED — playtest decides.**

- **F-2** (the total the party must deal) now reads **50,800 × party factor**,
  above, against a party DPS nobody has measured. Re-derived here; not tuned.
- **F-3** (the 120 s window and the arms' 7,000, "one decision taken twice")
  is now load-bearing in a way it was not when it was written: it is the fight's
  only timed gate and its only wall. Re-derive the pair **together**, against
  the new total, and do it from a playtest rather than from this table.

Neither flag is closed by this addendum. What it closes is the *stale* budget —
§9.2's 66,400 described a fight that no longer exists, and a stale number in a
frozen table is the kind of thing that gets tuned against.
