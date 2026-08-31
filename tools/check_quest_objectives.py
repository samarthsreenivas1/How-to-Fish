#!/usr/bin/env python3
"""Two ways a quest objective can be impossible while every other check passes.

check_content.py already proves a quest's species, items and waters keys all
EXIST. Existing is not the same as being reachable, and both rules below are
about objectives that name only real things and still can never complete.

RULE 1 - a `kill` objective must not carry `waters`.
    QuestService.objectiveMatches rejects on `objective.waters ~= payload.waters`,
    and the only kill notification in the codebase sends
    { player, species, rarity } with no waters at all. So any waters filter on
    a kill compares against nil and the objective is dead. Catch objectives are
    the opposite - FishingService passes `waters = cast.waters` - which is
    exactly what makes this easy to get wrong: the same field, on two objective
    types, one of which silently ignores it into a dead end.

RULE 2 - a species filter and a waters filter must agree.
    FishingService's `allowedRows` drops any row whose water is not the cast's,
    and `watersOf` reads a row with no `waters` as World.WATERS_OCEAN. So a
    creature can only ever be produced in its own water, and an objective that
    names a species AND a different water can never fire. This is the islet
    trap in its general form: a roster name like "wreck" is an ISLAND's
    interior water, so pairing it with an open-sea species reads fine and
    matches nothing.

  python3 tools/check_quest_objectives.py    # exits 1 on any impossible objective
"""

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
quests = (ROOT / "src" / "Shared" / "Data" / "Quests.luau").read_text()
creatures = (ROOT / "src" / "Shared" / "Data" / "Creatures.luau").read_text()
world = (ROOT / "src" / "Shared" / "Config" / "World.luau").read_text()

ocean = re.search(r'World\.WATERS_OCEAN\s*=\s*"([a-z]+)"', world)
OCEAN = ocean.group(1) if ocean else "ocean"

# A row with no `waters` is an ocean row - watersOf's fallback, mirrored here.
species_waters = {}
for m in re.finditer(r"Creatures\.items\.(\w+) = \{(.*?)\n\}", creatures, re.S):
    w = re.search(r'waters = "([a-z]+)"', m.group(2))
    species_waters[m.group(1)] = w.group(1) if w else OCEAN

problems = []
for qm in re.finditer(r"Quests\.items\.(\w+) = \{(.*?)\n\}", quests, re.S):
    qid, body = qm.group(1), qm.group(2)
    for om in re.finditer(r"\{[^{}]*type = \"(catch|kill)\"[^{}]*\}", body):
        obj, kind = om.group(0), om.group(1)
        w = re.search(r'waters = "([a-z]+)"', obj)
        sp = re.search(r'species = "([a-z_]+)"', obj)
        if kind == "kill" and w:
            problems.append(
                f"quest {qid}: kill objective filters waters='{w.group(1)}', but the kill "
                f"notification carries no waters - it can never complete"
            )
        if w and sp:
            want, actual = w.group(1), species_waters.get(sp.group(1))
            if actual is None:
                continue  # check_content owns "does this species exist"
            if want != actual:
                problems.append(
                    f"quest {qid}: objective wants '{sp.group(1)}' in waters='{want}', but that "
                    f"species only appears in '{actual}' - no cast can produce it"
                )

for p in problems:
    print("IMPOSSIBLE:", p)
if problems:
    sys.exit(1)
print("QUEST OBJECTIVES OK: no kill filters on waters, no species/waters contradictions")
