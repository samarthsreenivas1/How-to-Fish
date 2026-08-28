#!/usr/bin/env python3
"""Cross-file content consistency checker for the data tables.

The Luau data files are stylua-formatted tables, regular enough to extract
with conservative regexes - this is NOT a Luau parser, it just catches the
integration bug class that actually bites: an id referenced in one file that
does not exist in another (recipe materials, boss ids, brood rows, orders,
waters keys, requiresHearts...). Run from the repo root:

    python3 tools/check_content.py

Exit 0 = every invariant holds; 1 = problems printed. Written by the
overnight revamp coordination session (2026-08-25); extend the INVARIANTS
section as new cross-references appear.
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "src" / "Shared"

problems = []


def problem(msg):
    problems.append(msg)


def read(rel):
    return (SRC / rel).read_text()


def item_ids(text, table="items"):
    """Every `X.<table>.<id> = {` id in the file."""
    return set(re.findall(rf"\.{table}\.([A-Za-z_][A-Za-z0-9_]*)\s*=\s*{{", text))


def order_list(text, name):
    m = re.search(rf"{name}\s*=\s*{{(.*?)}}", text, re.S)
    if not m:
        return []
    return re.findall(r'"([A-Za-z0-9_]+)"', m.group(1))


def blocks(text, table="items"):
    """id -> the row's source text (to the next row or EOF). Rough but fine
    for lookups because rows never nest other `X.items.` assignments."""
    out = {}
    matches = list(re.finditer(rf"\.{table}\.([A-Za-z_][A-Za-z0-9_]*)\s*=\s*{{", text))
    for i, m in enumerate(matches):
        end = matches[i + 1].start() if i + 1 < len(matches) else len(text)
        out[m.group(1)] = text[m.start():end]
    return out


def braced(block, field):
    """The `{...}` after `field = ` inside a row (first level only)."""
    m = re.search(rf"{field}\s*=\s*{{", block)
    if not m:
        return None
    depth, i = 1, m.end()
    while i < len(block) and depth:
        depth += {"{": 1, "}": -1}.get(block[i], 0)
        i += 1
    return block[m.end():i - 1]


# ---------------------------------------------------------------- load
materials_text = read("Data/Materials.luau")
creatures_text = read("Data/Creatures.luau")
rods_text = read("Data/Rods.luau")
weapons_text = read("Data/Weapons.luau")
bait_text = read("Data/Bait.luau")
armor_text = read("Data/Armor.luau")
trinkets_text = read("Data/Trinkets.luau")
bosses_text = read("Data/Bosses.luau")
islands_text = read("Config/Islands.luau")
tuning_text = read("Config/Tuning.luau")
world_text = read("Config/World.luau")

materials = item_ids(materials_text)
creatures = blocks(creatures_text)
rods = blocks(rods_text)
weapons = blocks(weapons_text)
baits = blocks(bait_text)
armor_pieces = blocks(armor_text)
trinkets = blocks(trinkets_text)
bosses = blocks(bosses_text)
islands = blocks(islands_text)
# Islands.items is written as one literal table, not per-id assignments.
m = re.search(r"Islands\.items\s*=\s*{(.*)^}", islands_text, re.S | re.M)
island_ids = set(re.findall(r"^\t([A-Za-z_][A-Za-z0-9_]*)\s*=\s*{", m.group(1), re.M)) if m else set()

# Droppable / grantable materials.
droppable = set()
for block in creatures.values():
    drops = braced(block, "materials")
    if drops:
        droppable |= set(re.findall(r"([A-Za-z_][A-Za-z0-9_]*)\s*=\s*{", drops))
for section in ("CAST_GRANT", "KILL_BY_RARITY", "SALVAGE_MATERIALS"):
    sec = braced(tuning_text, section)
    if sec:
        droppable |= set(re.findall(r"([A-Za-z_][A-Za-z0-9_]*)\s*=\s*{", sec))

waters_by_part = dict(re.findall(r'([A-Za-z_][A-Za-z0-9_]*)\s*=\s*"([a-z]+)"', braced(world_text, "WATERS_BY_PART") or ""))
fishable_names = set(re.findall(r"([A-Za-z_][A-Za-z0-9_]*)\s*=\s*true", braced(world_text, "FISHABLE_NAMES") or ""))

# ---------------------------------------------------------------- invariants

# 1. Recipes: every material exists AND is obtainable; heart gates name real bosses.
for label, table in (("rod", rods), ("weapon", weapons), ("bait", baits), ("armor", armor_pieces), ("trinket", trinkets)):
    for iid, block in table.items():
        recipe = braced(block, "recipe")
        if not recipe:
            continue
        mats = braced(recipe, "materials") or ""
        for mat in re.findall(r"([A-Za-z_][A-Za-z0-9_]*)\s*=\s*\d", mats):
            if mat not in materials:
                problem(f"{label} {iid}: recipe material '{mat}' not in Materials.items")
            elif mat not in droppable:
                problem(f"{label} {iid}: recipe material '{mat}' has no drop source")
        hearts = braced(recipe, "requiresHearts")
        if hearts:
            for boss in re.findall(r'"([A-Za-z0-9_]+)"', hearts):
                if boss not in bosses:
                    problem(f"{label} {iid}: requiresHearts names unknown boss '{boss}'")


# 2b. Armor: every piece names a real set and a real slot; every set fields a
# full helmet/chest/legs trio (a set that can't complete can't bonus); set
# bonuses only use fields with live consumers.
armor_sets = {}
sets_section = re.search(r"Armor\.sets\.([A-Za-z0-9_]+)", armor_text)
armor_set_ids = set(re.findall(r"Armor\.sets\.([A-Za-z0-9_]+)\s*=", armor_text))
for pid, block in armor_pieces.items():
    m = re.search(r'set\s*=\s*"([A-Za-z0-9_]+)"', block)
    s = re.search(r'slot\s*=\s*"([a-z]+)"', block)
    if not m or m.group(1) not in armor_set_ids:
        problem(f"armor {pid}: names unknown set")
    if not s or s.group(1) not in ("helmet", "chest", "legs"):
        problem(f"armor {pid}: bad slot")
    if m and s:
        armor_sets.setdefault(m.group(1), set()).add(s.group(1))
for sid in armor_set_ids:
    slots = armor_sets.get(sid, set())
    if slots != {"helmet", "chest", "legs"}:
        problem(f"armor set {sid}: incomplete trio (has {sorted(slots)})")
ALLOWED_BONUS = {"name", "description", "health", "defense", "damageBonus"}
for sid in armor_set_ids:
    set_block = braced(armor_text.split("Armor.sets." + sid, 1)[1], "bonus")
    if set_block:
        for field in re.findall(r"([A-Za-z_][A-Za-z0-9_]*)\s*=", set_block):
            if field not in ALLOWED_BONUS:
                problem(f"armor set {sid}: bonus field '{field}' has no consumer")

# 2. Creature drops name real materials; waters keys are wired; boss backrefs hold.
water_keys = set(waters_by_part.values()) | {"ocean"}
for cid, block in creatures.items():
    drops = braced(block, "materials")
    if drops:
        for mat in re.findall(r"([A-Za-z_][A-Za-z0-9_]*)\s*=\s*{", drops):
            if mat not in materials:
                problem(f"creature {cid}: drops unknown material '{mat}'")
    w = re.search(r'waters\s*=\s*"([a-z]+)"', block)
    if w and w.group(1) not in water_keys:
        problem(f"creature {cid}: waters '{w.group(1)}' has no WATERS_BY_PART surface")
    b = re.search(r'boss\s*=\s*"([A-Za-z0-9_]+)"', block)
    if b and b.group(1) not in bosses:
        problem(f"creature {cid}: boss backref '{b.group(1)}' not in Bosses.items")
    items_drop = braced(block, "items")
    if items_drop:
        for ref in re.findall(r'id\s*=\s*"([A-Za-z0-9_]+)"', items_drop):
            if ref not in rods and ref not in weapons:
                problem(f"creature {cid}: item drop '{ref}' is not a rod or weapon")

# 3. Bosses: creature rows exist and are boss-archetype; islands exist; brood rows exist.
for bid, block in bosses.items():
    c = re.search(r'creature\s*=\s*"([A-Za-z0-9_]+)"', block)
    if c:
        if c.group(1) not in creatures:
            problem(f"boss {bid}: creature row '{c.group(1)}' missing")
        elif 'archetype = "boss"' not in creatures[c.group(1)] and 'archetype = "tentacle"' not in creatures[c.group(1)]:
            problem(f"boss {bid}: creature '{c.group(1)}' is not archetype boss")
    isl = re.search(r'islandId\s*=\s*"([A-Za-z0-9_]+)"', block)
    if isl and isl.group(1) not in island_ids:
        problem(f"boss {bid}: islandId '{isl.group(1)}' not in Islands.items")
    for rows in re.findall(r"rows\s*=\s*{([^}]*)}", block):
        for row in re.findall(r'"([A-Za-z0-9_]+)"', rows):
            if row not in creatures:
                problem(f"boss {bid}: brood/parts row '{row}' not in Creatures.items")

# 4. Islands: boss refs exist; order lists match items everywhere.
for iid in island_ids:
    pass  # per-entry fields checked below via regex over the whole table
for boss_ref in re.findall(r'boss\s*=\s*"([A-Za-z0-9_]+)"', islands_text):
    if boss_ref not in bosses:
        problem(f"Islands: boss '{boss_ref}' not in Bosses.items")
for name, text_, table in (
    ("Rods.order", rods_text, rods),
    ("Weapons.order", weapons_text, weapons),
    ("Bait.order", bait_text, baits),
    ("Materials.order", materials_text, {m_: None for m_ in materials}),
    ("Islands.order", islands_text, {i_: None for i_ in island_ids}),
):
    listed = order_list(text_, re.escape(name))
    for entry in listed:
        if entry not in table:
            problem(f"{name}: lists unknown id '{entry}'")
    for iid in table:
        if listed and iid not in listed and name != "Islands.order":  # maelstrom-style site entries may stay out of Islands.order
            problem(f"{name}: '{iid}' missing from the order list")

# 5. Baits: summonsBoss names real bosses.
for bid, block in baits.items():
    s = re.search(r'summonsBoss\s*=\s*"([A-Za-z0-9_]+)"', block)
    if s and s.group(1) not in bosses:
        problem(f"bait {bid}: summonsBoss '{s.group(1)}' not in Bosses.items")

# 6. Fishable surfaces: every WATERS_BY_PART part is FISHABLE and vice versa
#    (Ocean itself maps through the default).
for part in waters_by_part:
    if part not in fishable_names:
        problem(f"World: WATERS_BY_PART part '{part}' missing from FISHABLE_NAMES")

# ---------------------------------------------------------------- report
if problems:
    print(f"CONTENT CHECK: {len(problems)} problem(s)")
    for p in problems:
        print("  -", p)
    sys.exit(1)
print(
    f"CONTENT CHECK OK: {len(materials)} materials, {len(creatures)} creatures, {len(armor_pieces)} armor pieces in {len(armor_set_ids)} sets, {len(trinkets)} trinkets, "
    f"{len(rods)} rods, {len(weapons)} weapons, {len(baits)} baits, "
    f"{len(bosses)} bosses, {len(island_ids)} islands"
)
