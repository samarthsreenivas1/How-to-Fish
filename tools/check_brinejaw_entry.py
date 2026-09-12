#!/usr/bin/env python3
"""Gate six: the six Brinejaw `Entry` numbers, asserted against the real module.

    python3 tools/check_brinejaw_entry.py            # the gate
    python3 tools/check_brinejaw_entry.py --control   # the positive control
    python3 tools/check_brinejaw_entry.py --keep      # leave the assembled
                                                     # file and print `luau <path>`

WHY THIS EXISTS. `BrinejawPath.Entry` (the cutscene-only arrival channel,
docs/boss-cutscenes-redesign.md SS2) is an authored 18-knot spline joined to
the rest pose and re-parametrised by arc length. Every number the choreography
is aimed from - the breach radius the camera sits at, the apex the arc clears,
the Entry at which each link surfaces - is a CONSEQUENCE of those knots, and
the four standing gates cannot see any of it: stylua and selene read style,
rojo reads the tree, and `luau-compile` proves only that the file parses. A
knot nudged by a future author would leave a serpent that stretches to double
length, or breaches inside the lighthouse, or never gets out of the water, and
every gate would stay green. This runs the REAL module and measures.

It is also the only check that sees the class of defect this codebase keeps
hitting: a value that is right in one file and stale in another. Hence GATE 0,
which is not in the design doc - the spline's first two knots MUST be computed
from `restPoint` at run time (the join and its Catmull-Rom ghost), never
pasted, and the gate proves it by perturbing REST.TAIL_OUT and watching the
anchor move.

HOW IT RUNS THE MODULE OUTSIDE STUDIO. `BrinejawPath.luau` is pure geometry -
no Instance, no service, no CFrame, only `Vector3.new`/`Vector3.zero` - which
is exactly what makes it gateable. The driver concatenates three files into one
Luau chunk and runs `luau` on it:

    tools/brinejaw_entry_stub.luau    a 50-line Vector3 (the four operations
                                      the module actually performs)
    src/Shared/Modules/BrinejawPath.luau, wrapped in `(function() ... end)()`
    tools/brinejaw_entry_probe.luau   the asserts

Wrapping the module in a function is deliberate: its 26 top-level locals
become 26 function locals, well inside Luau's 200-register limit either way,
and nothing else about it changes.

GATE 8 IS NOT IN LUAU AT ALL. The nil-collapse's ambient step (see the probe's
INFO lines) is only acceptable while the skull is moving, and whether it lands
there depends on four numbers spread across two files - BrinejawIntro's
schedule and slump window, and the controller's `EASE.entry` and `ENTRY.HOME`.
`ordering_check` reads all four out of the files and simulates the controller's
filter, so a retune of any one of them fails here instead of in Studio.

THE POSITIVE CONTROL is not optional decoration. A green run on a healthy
module looks exactly like a probe that measured nothing, so `--control` drops
the APEX knot from y 72 to y 40 - below the broken lantern - and the run must
FAIL. A control that passes means this gate is inert.
"""

import argparse
import math
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MODULE = ROOT / "src" / "Shared" / "Modules" / "BrinejawPath.luau"
STUB = ROOT / "tools" / "brinejaw_entry_stub.luau"
PROBE = ROOT / "tools" / "brinejaw_entry_probe.luau"
CONTROLLER = ROOT / "src" / "Client" / "Controllers" / "BrinejawBodyController.luau"
INTRO = ROOT / "src" / "Client" / "Cutscenes" / "BrinejawIntro.luau"

# The shapes BrinejawIntro's schedule rows may use, by the name it gives them.
SHAPES = {
    "linear": lambda x: min(max(x, 0.0), 1.0),
    "smooth": lambda x: (lambda u: u * u * (3 - 2 * u))(min(max(x, 0.0), 1.0)),
    "easeOut": lambda x: (lambda u: 1 - (1 - u) * (1 - u))(min(max(x, 0.0), 1.0)),
    "easeIn": lambda x: (lambda u: u * u)(min(max(x, 0.0), 1.0)),
}
STEP_HZ = 60.0
# How much of the ramp has to be left on each side of the collapse. Landing on
# the ramp's last five frames is landing on its edge: the drawn slump lags the
# attribute by its own ease and a frame or two of jitter would push the ambient
# step onto a still skull. 0.1 s is six frames of the 0.7-s ramp.
MIN_MARGIN = 0.10


def number_table(text: str, name: str) -> dict:
    """The `local <name> = { key = number, ... }` table, as a dict."""
    match = re.search(r"local " + name + r" = \{(.*?)\n\}", text, re.S)
    if not match:
        return {}
    return {k: float(v) for k, v in re.findall(r"(\w+) = (-?[\d.]+)\s*,", match.group(1))}


def ordering_check() -> int:
    """GATE 8: the nil-collapse must land INSIDE the slump ramp.

    The entry branch of `pointAt` returns ahead of every blend, and therefore
    ahead of the ambient breath and sway - so the frame the controller collapses
    `Entry` to nil, the ambient re-enters as a step (1.63 studs at ENTRY.HOME;
    the probe prints it). That is acceptable only while the skull is already
    moving, i.e. inside BrinejawIntro's slump ramp, where it moves 26 studs in
    0.7 s. Whether it lands there is a consequence of FOUR numbers in two files
    - the schedule's last row and its shape, the slump window, EASE.entry and
    ENTRY.HOME - and nothing else checks that they still agree. So they are
    READ here (never restated) and the controller's own first-order filter is
    simulated at 60 Hz.
    """
    controller = CONTROLLER.read_text()
    intro = INTRO.read_text()

    ease = re.search(r"local EASE = \{.*?\n\tentry = ([\d.]+),", controller, re.S)
    thresholds = re.search(r"local ENTRY = \{ HOME = ([\d.]+), ATTR_HOME = ([\d.]+)", controller)
    times = number_table(intro, "T")
    rows = re.findall(
        r"\{ t0 = T\.(\w+), t1 = T\.(\w+), from = ([\d.]+), to = ([\d.]+), shape = (\w+) \}",
        intro,
    )
    slump = re.search(r'kit\.track\(T\.(\w+), T\.(\w+), "in"', intro)

    if not (ease and thresholds and times and rows and slump):
        print("GATE\tcollapse-inside-slump\tFAIL\tcould not parse the schedule, the ease rate")
        print("  or the slump window - this gate cannot verify the ordering, so it refuses to pass.")
        return 1

    rate = float(ease.group(1))
    home, attr_home = float(thresholds.group(1)), float(thresholds.group(2))
    schedule = [(times[a], times[b], float(c), float(d), SHAPES[shape]) for a, b, c, d, shape in rows]
    slump0, slump1 = times[slump.group(1)], times[slump.group(2)]

    def target(t: float) -> float:
        if t <= schedule[0][0]:
            return schedule[0][2]
        for t0, t1, start, end, shape in schedule:
            if t < t1:
                return start + (end - start) * shape((t - t0) / (t1 - t0))
        return schedule[-1][3]

    eased, t, crossing = 0.0, schedule[0][0], None
    while t < slump1 + 4.0 and crossing is None:
        wanted = 1.0 if target(t) >= attr_home else target(t)
        eased += (wanted - eased) * (1 - math.exp(-rate / STEP_HZ))
        if eased >= home:
            crossing = t
        t += 1 / STEP_HZ

    if crossing is None:
        print(
            f"GATE\tcollapse-inside-slump\tFAIL\tthe eased Entry never reaches HOME ({home}) at "
            f"EASE.entry {rate}/s - the collapse would only happen when the attribute is removed"
        )
        return 1
    ok = (crossing - slump0) >= MIN_MARGIN and (slump1 - crossing) >= MIN_MARGIN
    detail = (
        f"eased Entry crosses HOME {home} at t = {crossing:.3f}; slump ramp {slump0:.2f}..{slump1:.2f} "
        f"(margins {crossing - slump0:+.3f} / {slump1 - crossing:+.3f}, need {MIN_MARGIN:.2f});"
        f" EASE.entry {rate}/s"
    )
    print(f"GATE\tcollapse-inside-slump\t{'PASS' if ok else 'FAIL'}\t{detail}")
    if not ok:
        print("  The ambient step would land on a frame where the skull is not moving. Either move")
        print("  the slump ramp onto the collapse or give the schedule's last row a flatter finish.")
    return 0 if ok else 1


def assemble(control: bool) -> str:
    module = MODULE.read_text()
    # `--!nonstrict` is a file-level hot comment and means nothing inside a
    # function body; strip it so Luau does not warn about a stray directive.
    module = re.sub(r"^--!\w+\n", "", module)
    parts = [
        STUB.read_text(),
        f"local CONTROL = {'true' if control else 'false'}\n",
        "local BrinejawPath = (function()\n",
        module,
        "\nend)()\n",
        PROBE.read_text(),
    ]
    return "".join(parts)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--control", action="store_true", help="perturb one knot; the run must FAIL")
    ap.add_argument("--keep", action="store_true", help="keep the assembled chunk and print its path")
    args = ap.parse_args()

    if shutil.which("luau") is None:
        print("BRINEJAW ENTRY CHECK: `luau` not on PATH - install it with `brew install luau`.")
        print("  (The same formula ships `luau-compile`, which gate five uses.)")
        return 1
    for path in (MODULE, STUB, PROBE):
        if not path.exists():
            print(f"BRINEJAW ENTRY CHECK: missing {path.relative_to(ROOT)}")
            return 1

    chunk = assemble(args.control)
    directory = tempfile.mkdtemp(prefix="brinejaw_entry_")
    assembled = Path(directory) / "brinejaw_entry_run.luau"
    assembled.write_text(chunk)

    run = subprocess.run(["luau", str(assembled)], capture_output=True, text=True)
    sys.stdout.write(run.stdout)
    if run.stderr.strip():
        sys.stderr.write(run.stderr)

    if args.keep:
        print(f"\nassembled chunk kept: {assembled}\n  re-run it by hand with:  luau {assembled}")
    else:
        shutil.rmtree(directory, ignore_errors=True)

    if run.returncode != 0:
        print("BRINEJAW ENTRY CHECK: the probe did not run to completion (see above).")
        return 1

    gates = [line.split("\t") for line in run.stdout.splitlines() if line.startswith("GATE\t")]
    if not gates:
        print("BRINEJAW ENTRY CHECK: the probe reported no gates - it measured nothing.")
        return 1
    failed = [row for row in gates if row[2] != "PASS"]

    ordering = ordering_check()

    if args.control:
        if failed:
            print(
                f"\nCONTROL OK: {len(failed)} of {len(gates)} measured gates failed on the perturbed "
                f"knot ({', '.join(row[1] for row in failed)}). The ordering gate reads the schedule "
                f"rather than the knots and is unaffected by design."
            )
            return 0
        print("\nCONTROL FAILED: every gate still passed with the APEX knot at y 40. This checker is inert.")
        return 1

    if failed or ordering != 0:
        print(f"\nBRINEJAW ENTRY CHECK: {len(failed) + ordering} of {len(gates) + 1} gates FAILED.")
        return 1
    print(f"\nBRINEJAW ENTRY CHECK OK: {len(gates) + 1} gates pass.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
