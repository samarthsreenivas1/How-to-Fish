# Pyrelisk, the Ashfall Colossus — what's left

Working checklist for the volcano boss. Written 2026-08-31, mid-build.

The fight: a 270-stud obsidian rock golem rooted in the caldera lake of its
own arena. Players circle it on a flat rim path across a moat of lava, shoot
it (the moat makes melee geometrically impossible — no `rangedOnly` flag), and
earn a punish window by baiting a hand-slam onto one of nine monoliths. The
arm that lands stays down across the moat and **is the ramp they climb**.

---

## Done

- **Arena mesh** — `assets/arena_gen.py build_pyrelisk` → `arena_pyrelisk.glb`, 12 objects
- **Colossus mesh** — `assets/boss_gen.py build_pyrelisk` → `boss_pyrelisk.glb`, 14 objects
- **Arena placement** — `BossArenas.volcano`: `meshBottom = -84.7` (measured off the
  export, not derived), palette, `model`, and the nine `stones`
- **The rig** — `src/Shared/Modules/PyreliskPath.luau`: joints, 7 poses, seam/vent
  tables, `rampCFrame`/`deckCFrames`, the aim-latching contract
- **The renderer** — `src/Client/Controllers/PyreliskBodyController.luau`, registered
  in `init.client.luau`; draws stand-ins until the pack is imported
- **Server rig plumbing** — `CreatureService`: `PyreliskPath` require, the five rig
  attributes (+ `Planted`), `colossusState` branch, `RIG_POSE` + generic publish
- **All five attacks** — `ATTACK_HANDLERS.handfall` (opener and bait), `rimsweep`,
  `ventbreath`, `ashfall`, `shardhurl`, all in `CreatureService`, all latching
  through `pyreliskLatch`
- **The Bosses.luau row** — `Bosses.items.pyrelisk`: entrenched, three stances, the
  phase table and the five-attack book, `minReach = 120` / `maxReach = 200`
- **Spawn height** — arena floor probed rather than assumed at `World.WATER_Y`
  (`BossService.arenaPosition`, `BossArenaService.ringPositions`)
- **`Creatures.items.pyrelisk` re-keyed** — true-size body, `scale = 1.0`,
  `hitRadius = 96` (the moat)
- **The mount layer** — `PyreliskPath.climbSlabs` + `openPyreliskMount` /
  `shakePyreliskMount` / `pyreliskLavaWatch` / `pyreliskVentSwing`: anchored
  invisible slabs for the window only, three breakable vents, the shake-off, and
  the lava rescue (which now runs in every mode, because the moat is the melee
  gate and it is enforced by damage — the basalt under the sheet is flat)
- **The collapse death** — `updateBossCollapse` drives the `collapse` pose, both
  arms (`poseFor` returns it for either side)
- **Import rows** — `docs/import-checklist.md` 7n (arena) and 7o (pack)
- **A verification tool** — `scratchpad/floor_check.py`: raycasts the *exported* glb at
  a named spot and reports the height **and the object hit**

---

## 1. Current known-open

The blockers are gone: the fight runs end to end — rise, five attacks, bait,
window, climb, vents, collapse. What is genuinely still open:

- [x] **The seam route is BUILT (2026-09-06), the fight's original core loop.**
      Seams open on the committing flank's windup+strike (`seams = "arm"|"both"`
      per attack row), a shot passing within 9 studs of an open seam's point —
      from the outward side — lands through the untargetable gate and fills that
      flank's meter (`SEAM_METER_HP` 2600: Cinderlock ~24s at full uptime), and a
      full meter drops THAT arm as the ramp (`seamStagger = 14` vs the bait's 20,
      so the monolith stays the premium route). Meters are repeatable; broken
      flanks scar permanently (`SeamsBroken`, monotonic). Chest = bit 0, reserved
      for phase 3, structurally unreachable (flank 0, in neither mask). The
      attribute contract lives in PyreliskBodyController ("THE ATTRIBUTE
      CONTRACT"); server, body renderer and HUD all quote it byte-identically.
      The open-mask lifecycle is an INVARIANT, not paired calls: placeColossus
      sweeps `SeamsOpen = 0` whenever no attack is running, so no exit path can
      leak an open seam. Still open on this system: tuning (meter HP, radius,
      seamStagger), and impact VFX originate at the model's PrimaryPart rather
      than the seam (CombatService.landHit, client lane's call).
- [ ] **TTK and party scaling are untuned.** 40,000 HP, three vents at 7% each, one
      shared hit counter per vent (four swings breaks it however many people are
      swinging). Nothing here has been measured against a real party.
- [ ] **Window-only damage is an open design decision.** Right now the boss is
      `untargetable` outside the stagger, so all damage happens in the window and
      the rest of the fight is positioning. That may be the fight, or it may be
      why it feels long — it is a decision nobody has made on purpose yet.
- [ ] **Studio imports are still owed** (rows 7n/7o below). Everything is drawn
      from stand-ins until then, which hides exactly the placement errors the
      stand-ins exist to expose.
- [ ] **Stances.** `stances = 3` publishes, but no pose varies by stance yet — each
      one it loses should visibly cost it ground.

## 2. Presentation — DONE (2026-08-31 agents; kept for the record)

- [x] **Third-person camera** — `CameraController`'s THRONE variant: distance 64,
      the eye on its own clamped boom so looking up at the body doesn't collapse
      the orbit through the floor; the look direction stays the player's aim
      (RangedController reads it). Height-gated so falling off the summit
      restores first person.
- [x] **Arena fog** — `WeatherController`: per-arena mood bounds (radius 340 +
      height gate; the old 140-stud disc dropped the mood on most of the rim
      path), a `summit` mood selected for the lair only. Density 0.30 — NOT the
      0.19 a curve-fit suggested, which would have been clearer than open ocean
      (world Atmosphere default is 0.28); the distance work is done by Haze.
- [x] **Arena materials** — `BossArenaService`: `Seam` joined the glow markers
      (Neon), `Lava` is Neon + `CanCollide = false` via HAZARD_MARKERS, kept
      queryable on purpose — a non-queryable lake would blind `floorY` and
      re-arm the 292-stud spawn bug.

## 3. Import + verification

- [ ] Import both glbs per rows 7n/7o — or run `tools/studio_import.lua` in the
      Studio Command Bar, which does all 21 owed files and applies the
      fidelities itself. **`PyreliskArena_Rim` needs PreciseConvexDecomposition**
      — a default hull fills the overhang and turns the player containment into
      a ramp.
- [ ] Re-run `floor_check.py` against the **climb route** once the slabs are placed —
      the ramp is exactly the asymmetric, off-centre target the tool is for.
- [ ] Tune seam health, stagger duration, phase pacing, damage. Now unblocked:
      ranged shots in third person were being discarded server-side until `8b14f47`.

---

## Traps — things that break silently

Each of these has already bitten once, here or in a neighbouring lane.

- **`roblox Z = -blender y`.** The generator prints monolith positions already
  negated ("ROBLOX rel"). All nine `stones` were mirrored once; a mirrored stone
  still exists, still sits on the floor, and only ever disagrees with the rock the
  player can see.
- **Don't sink the lava lake.** Flush is load-bearing twice: a pit is a fall in an
  arena whose rule is horizontal movement only, *and* the ocean slab is solid with
  its top face at Y = 0, so a sunken floor is authored inside collision.
- **`meshBottom` is a decision, not a measurement** — where authored z=0 should
  land. It equals the bbox floor only when that answer is zero. And the floor is set
  by whatever hangs lowest, which here is the *cloud deck*, not the mountain.
- **A number derived from a constant is a claim; measured off the built objects it
  is evidence.** The old HANDOFF said −302; the real floor is −376.7.
- **An unfed rig looks like a rig at rest.** The controller's `or ""` / `or 0`
  defaults mean a missing publish branch presents as "the animation isn't hooked up
  yet" (this is currently true of Gnashroot — its rig is dark).
- **Anything the fight depends on visually belongs in the controller, not the import
  step.** `Core`/`Seam`/`Eyes` are forced to Neon in `makePiece`.
- **`stylua` in write mode on a shared file** will reformat other lanes' uncommitted
  work. `--check` first; format only if the diff is yours.
