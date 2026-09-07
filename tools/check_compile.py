#!/usr/bin/env python3
"""Gate five: actually COMPILE every .luau under src/.

Why this exists (2026-09-06): the game would not boot. CreatureService.luau
(333 top-level locals) and CreatureEventController.luau (252) blew past
Luau's 200-register limit at chunk scope and failed to compile - and all
four existing gates stayed green the whole time. stylua only formats,
selene lints the AST without allocating registers, check_content.py reads
data tables, and *rojo packages Luau without compiling it*. Nothing in the
pipeline had ever asked the compiler for its opinion. This script does:

    python3 tools/check_compile.py

Exit 0 = every file compiles; 1 = at least one CompileError, printed with
its file path, line and column exactly as luau-compile reports it. Files
are compiled ONE AT A TIME on purpose: luau-compile stops at the first bad
file in a multi-file invocation, so a batch run would hide every failure
after the first.

--------------------------------------------------------------- tripwire
The second half of this script is a WARNING (never a failure) at 180
top-level `local` declarations per file, so a lane gets a shoulder tap
before it walks off the cliff mid-slice.

Read the threshold as a smoke alarm, not as the fire code. The real limit
is REGISTERS, not lines beginning with `local`:

  * `local a, b, c = f()` is ONE line and THREE registers - this script
    expands comma lists, but that is still an approximation.
  * temporaries, upvalues captured by nested closures, and expression
    scratch space all consume registers the source never names.
  * the ceiling is per-function; the chunk body is itself a function, so
    only CHUNK-SCOPE locals count toward the 200 that killed us. A deeply
    nested `local` inside a function is charged to that function instead.

So a file can sit at 170 by this count and still fail, or carry 190 and
compile. The count is a hint about direction; `luau-compile` above is the
truth. When they disagree, the compiler wins - always.
"""

import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "src"

TRIPWIRE = 180
COMPILER = "luau-compile"

# `--null` runs the full compile (register allocation included) and throws
# the bytecode away; `--binary` would spray it at stdout.
#
# `-O0` is pinned deliberately. The 2026-09-06 game-down (333 chunk locals)
# fails at EVERY -O level, tested empirically on the broken blob — but the
# consolidation lane reports that near the margin, higher levels can shave
# register pressure and mask a file that Studio's own compile then rejects.
# Strictest wins: a marginal false positive here is a cheap consolidation
# prompt; a masked true positive is the game refusing to boot with five
# gates green.
COMPILE_ARGS = [COMPILER, "--null", "-O0"]


def local_names(path):
    """Approximate chunk-scope local count: `local` lines, comma-expanded.

    Deliberately crude - see the register caveat in the module docstring.
    Only lines starting at column 0 are counted, since an indented `local`
    belongs to some inner function and is charged to that function's own
    register budget, not the chunk's.
    """
    count = 0
    for line in path.read_text(errors="replace").splitlines():
        if not line.startswith("local "):
            continue
        rest = line[len("local ") :]
        if rest.startswith("function"):
            count += 1  # `local function f()` binds exactly one name
            continue
        names = rest.split("=", 1)[0]
        count += len([n for n in names.split(",") if n.strip()])
    return count


def main():
    files = sorted(SRC.rglob("*.luau"))
    if not files:
        print(f"COMPILE CHECK: no .luau files under {SRC} - wrong cwd?")
        return 1

    failures = []
    for path in files:
        rel = path.relative_to(ROOT)
        try:
            proc = subprocess.run(
                COMPILE_ARGS + [str(path)],
                capture_output=True,
                text=True,
            )
        except FileNotFoundError:
            print(
                f"COMPILE CHECK: `{COMPILER}` is not on PATH.\n"
                f"  Install it with `brew install luau` (it ships in the luau\n"
                f"  formula alongside `luau` and `luau-analyze`). This gate is\n"
                f"  the only thing standing between the repo and a game that\n"
                f"  does not boot - do not skip it."
            )
            return 1
        if proc.returncode != 0:
            # Diagnostics go to stderr; stdout carries only the KLOC/bytecode
            # stats line, which is noise next to a CompileError.
            detail = (proc.stderr.strip() or proc.stdout.strip())
            # luau-compile prints paths as it received them; show ours.
            detail = detail.replace(str(path), str(rel)).replace(
                f"./{rel}", str(rel)
            )
            failures.append((rel, detail or f"exit {proc.returncode}"))

    tripped = []
    for path in files:
        n = local_names(path)
        if n >= TRIPWIRE:
            tripped.append((path.relative_to(ROOT), n))

    for rel, n in sorted(tripped, key=lambda t: -t[1]):
        print(
            f"COMPILE CHECK WARNING: {rel} declares ~{n} chunk-scope locals "
            f"(tripwire {TRIPWIRE}, hard register limit 200). Split it before "
            f"it stops compiling."
        )

    if failures:
        print(f"COMPILE CHECK: {len(failures)} file(s) failed to compile")
        for rel, detail in failures:
            for line in detail.splitlines():
                print("  -", line)
        print(
            "  These files are packaged by rojo as-is and will error at "
            "require() time in Studio - the game does not boot."
        )
        return 1

    print(
        f"COMPILE CHECK OK: {len(files)} .luau files compiled"
        + (f", {len(tripped)} over the {TRIPWIRE}-local tripwire" if tripped else "")
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
