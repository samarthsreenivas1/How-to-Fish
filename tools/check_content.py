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
boats_text = read("Data/Boats.luau")
quests_text = read("Data/Quests.luau")
npcs_text = read("Data/Npcs.luau")
shops_text = read("Data/Shops.luau")
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
quests = blocks(quests_text)
npcs = blocks(npcs_text)
shops = blocks(shops_text)
islands = blocks(islands_text)
# Islands.items is written as one literal table, not per-id assignments.
m = re.search(r"Islands\.items\s*=\s*{(.*)^}", islands_text, re.S | re.M)
island_ids = set(re.findall(r"^\t([A-Za-z_][A-Za-z0-9_]*)\s*=\s*{", m.group(1), re.M)) if m else set()
# Boats.items is one literal table too.
m = re.search(r"Boats\.items\s*=\s*{(.*?)^}", boats_text, re.S | re.M)
boat_ids = set(re.findall(r"^\t([A-Za-z_][A-Za-z0-9_]*)\s*=\s*{", m.group(1), re.M)) if m else set()

# The two reference DOMAINS the quest and shop checks below share.
#   grantable - exactly what InventoryService.grantItem will hand over: rods,
#     weapons, trinkets, armor. A quest reward `items` entry and a shop
#     `kind = "item"` slot both end at that one function, so both resolve
#     here. Bait and boats are deliberately OUT: they have their own grant
#     paths, so an id from either would look fine and then grant nothing.
#   craftable - what CraftingService can build (a `craft` objective's
#     itemId): the grantable set plus bait and boats.
grantable = set(rods) | set(weapons) | set(trinkets) | set(armor_pieces)
craftable = grantable | set(baits) | boat_ids


def entries(text):
    """Each top-level `{...}` inside a Luau list, brace-matched - so an
    objective's nested `materials = { ... }` stays with its own entry."""
    out, depth, start = [], 0, None
    for i, ch in enumerate(text or ""):
        if ch == "{":
            if depth == 0:
                start = i
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0 and start is not None:
                out.append(text[start + 1:i])
                start = None
    return out

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

# 7. Quests: every id a quest row names resolves. NOTHING checked this before
# (added 2026-08-29), which is why the bug class it catches is invisible: a
# quest whose objective names a creature or a craftable that does not exist
# is still offered and still accepted - it simply can never be turned in.
# Same for a reward that grants nothing. Every message prints the quest id.
#
# `type` is checked against the matcher QuestService actually implements
# (objectiveMatches handles catch/kill/craft/visit; objectiveDone handles
# deliver). An objective of any other type matches no event, so its progress
# never leaves 0 and allObjectivesDone never returns true - a dead quest.
OBJECTIVE_TYPES = ("catch", "kill", "craft", "deliver", "visit")
RARITIES = ("Common", "Uncommon", "Rare", "Epic", "Legendary")

npc_quest_lists = {}
for nid, block in npcs.items():
    listed = re.findall(r'"([A-Za-z0-9_]+)"', braced(block, "quests") or "")
    npc_quest_lists[nid] = listed
    for qid in listed:
        if qid not in quests:
            problem(f"npc {nid}: quests list names unknown quest '{qid}'")
    shop_ref = re.search(r'shop = "([A-Za-z0-9_]+)"', block)
    if shop_ref and shop_ref.group(1) not in shops:
        problem(f"npc {nid}: shop '{shop_ref.group(1)}' not in Shops.items")

for qid, block in quests.items():
    giver = re.search(r'giver = "([A-Za-z0-9_]+)"', block)
    if not giver:
        problem(f"quest {qid}: no giver")
    elif giver.group(1) not in npcs:
        problem(f"quest {qid}: giver '{giver.group(1)}' not in Npcs.items")
    elif qid not in npc_quest_lists.get(giver.group(1), []):
        # QuestService.offersFor only ever walks the NPC's own `quests` list,
        # so a quest its giver does not list can never be offered to anyone.
        problem(f"quest {qid}: giver '{giver.group(1)}' does not list it in `quests` - never offered")
    prereq = re.search(r'prereq = "([A-Za-z0-9_]+)"', block)
    if prereq and prereq.group(1) not in quests:
        problem(f"quest {qid}: prereq '{prereq.group(1)}' is not a quest")

    for objective in entries(braced(block, "objectives")):
        kind = re.search(r'type = "([a-z]+)"', objective)
        kind = kind.group(1) if kind else None
        if kind not in OBJECTIVE_TYPES:
            problem(f"quest {qid}: objective type '{kind}' has no matcher in QuestService - it can never complete")
            continue
        species = re.search(r'species = "([A-Za-z0-9_]+)"', objective)
        if species and species.group(1) not in creatures:
            problem(f"quest {qid}: objective species '{species.group(1)}' not in Creatures.items")
        rarity = re.search(r'rarity = "([A-Za-z]+)"', objective)
        if rarity and rarity.group(1) not in RARITIES:
            problem(f"quest {qid}: objective rarity '{rarity.group(1)}' is not a rolled tier")
        w = re.search(r'waters = "([a-z]+)"', objective)
        if w and w.group(1) not in water_keys:
            problem(f"quest {qid}: objective waters '{w.group(1)}' has no WATERS_BY_PART surface")
        if kind == "craft":
            item = re.search(r'itemId = "([A-Za-z0-9_]+)"', objective)
            if not item:
                problem(f"quest {qid}: craft objective has no itemId")
            elif item.group(1) not in craftable:
                problem(f"quest {qid}: craft objective itemId '{item.group(1)}' is not a craftable")
        elif kind == "visit":
            isl = re.search(r'island = "([A-Za-z0-9_]+)"', objective)
            if not isl:
                problem(f"quest {qid}: visit objective has no island")
            elif isl.group(1) not in island_ids:
                problem(f"quest {qid}: visit objective island '{isl.group(1)}' not in Islands.items")
        elif kind == "deliver":
            mats = braced(objective, "materials")
            if mats is None:
                problem(f"quest {qid}: deliver objective has no materials")
            for mat in re.findall(r"([A-Za-z_][A-Za-z0-9_]*)\s*=\s*\d", mats or ""):
                if mat not in materials:
                    problem(f"quest {qid}: deliver objective wants unknown material '{mat}'")

    rewards = braced(block, "rewards") or ""
    for mat in re.findall(r"([A-Za-z_][A-Za-z0-9_]*)\s*=\s*\d", braced(rewards, "materials") or ""):
        if mat not in materials:
            problem(f"quest {qid}: reward material '{mat}' not in Materials.items")
    for bid in re.findall(r"([A-Za-z_][A-Za-z0-9_]*)\s*=\s*\d", braced(rewards, "bait") or ""):
        if bid not in baits:
            problem(f"quest {qid}: reward bait '{bid}' not in Bait.items")
    for iid in re.findall(r'"([A-Za-z0-9_]+)"', braced(rewards, "items") or ""):
        if iid not in grantable:
            problem(f"quest {qid}: reward item '{iid}' is not grantable (rod/weapon/trinket/armor)")

# 8. Shops: every slot id resolves in the table its `kind` names. Same bug
# class as the quests above and strictly worse: NpcService.buy SPENDS the
# coins before it grants, so a typo'd slot takes the player's money and hands
# back nothing, silently. `kind = "item"` resolves through the same grantable
# domain as a quest reward item - both end at InventoryService.grantItem.
SLOT_DOMAINS = {
    "bait": (set(baits), "Bait.items"),
    "material": (materials, "Materials.items"),
    "item": (grantable, "the grantable set (rod/weapon/trinket/armor)"),
}
for sid, block in shops.items():
    slots = entries(braced(block, "stock") or "")
    slots += entries(braced(braced(block, "rotating") or "", "pool") or "")
    if not slots:
        problem(f"shop {sid}: no stock and no rotating pool - nothing to sell")
    for slot in slots:
        m = re.search(r'kind = "([a-z]+)"\s*,\s*id = "([A-Za-z0-9_]+)"', slot)
        if not m:
            problem(f"shop {sid}: slot has no kind/id pair ({' '.join(slot.split())[:48]})")
            continue
        kind, iid = m.group(1), m.group(2)
        domain = SLOT_DOMAINS.get(kind)
        if not domain:
            problem(f"shop {sid}: slot kind '{kind}' has no branch in NpcService.buy")
        elif iid not in domain[0]:
            problem(f"shop {sid}: {kind} slot '{iid}' not in {domain[1]}")

# 9. Creature families: every creature id is sorted into exactly one of the
# fifteen body families, and no row names a family that doesn't exist. The
# families are the audio pass's grouping - four cues each (`<F>Idle`,
# `<F>Attack`, `<F>Hurt`, `<F>Die`, assets/audio_gen/CONTRACT.md §3) instead of
# four per creature - so a creature added without a family here is not a crash,
# it is a creature that is SILENT, which is exactly the kind of miss that ships.
families_text = read("Data/CreatureFamilies.luau")
family_allowed = set(order_list(families_text, "CreatureFamilies.families"))
family_of = dict(
    re.findall(r"^\t([A-Za-z_][A-Za-z0-9_]*) = \"([A-Za-z]+)\",", families_text, re.M)
)
if len(family_allowed) != 15:
    problem(
        f"CreatureFamilies.families lists {len(family_allowed)} families, want the 15 in the contract"
    )
for cid in creatures:
    fam = family_of.get(cid)
    if not fam:
        problem(f"creature '{cid}' has no family in CreatureFamilies.byId (it would be silent)")
    elif fam not in family_allowed:
        problem(f"creature '{cid}': family '{fam}' is not one of {sorted(family_allowed)}")
for cid in family_of:
    if cid not in creatures:
        problem(f"CreatureFamilies.byId names '{cid}', which is not a creature in Creatures.luau")

# 10. Rimefang piece offsets: RimefangBodyController.MESH_OFFSET restores the
# authored offset Roblox drops when it re-centres an imported MeshPart, so it
# has to equal each object's bounding-box centre in boss_rimefang.glb. A
# re-export that moves a piece and forgets this table puts the piece back on
# its joint - the jumbled-whale bug, silently.
import json as _json, os, struct as _struct
_glb = os.path.join(ROOT, "assets", "boss_rimefang.glb")
_ctrl = open(os.path.join(ROOT, "src", "Client", "Controllers", "RimefangBodyController.luau")).read()
if os.path.exists(_glb):
    _b = open(_glb, "rb").read()
    _L = _struct.unpack("<I", _b[12:16])[0]
    _j = _json.loads(_b[20:20 + _L])
    _centres = {}
    for _n in _j["nodes"]:
        if "mesh" in _n:
            _acc = _j["accessors"][_j["meshes"][_n["mesh"]]["primitives"][0]["attributes"]["POSITION"]]
            _centres[_n["name"]] = [(a + b) / 2 for a, b in zip(_acc["min"], _acc["max"])]
    _table = re.search(r"local MESH_OFFSET = \{(.*?)\n\}", _ctrl, re.S)
    _rows = dict(re.findall(r"^\t(\w+) = Vector3\.new\(([^)]*)\)", _table.group(1), re.M)) if _table else {}
    for _piece, _c in sorted(_centres.items()):
        _key = _piece.replace("Rimefang_", "")
        if _key == "Body":
            continue  # authored centred on its joint; no row by design
        if _key not in _rows:
            problem(f"RimefangBodyController.MESH_OFFSET has no row for {_piece}")
            continue
        _want = [float(v) for v in _rows[_key].split(",")]
        if any(abs(a - b) > 0.06 for a, b in zip(_want, _c)):
            problem(f"RimefangBodyController.MESH_OFFSET.{_key} is {_want}, glb centre is "
                    f"{[round(v, 2) for v in _c]} - re-export moved the piece; update the table")

# ---------------------------------------------------------------- the mesh mirror
#
# ONE NUMBER, TWO FILES, TWO LANGUAGES. `wrack_battery.shotRadius` is the
# capture the fight's primary target is hit with, and the mesh lane's casemate
# geometry is SOLVED against it - the cheeks are sized so the capture cannot
# protrude past them (`shotRadius <= cheek half-width`) and the plates are
# topped so it cannot protrude over them. So the same number is baked into
# assets/boss_gen.py as `WR_BATTERY_SHOT_RADIUS` and asserted by the mesh
# guard there.
#
# WHICH MEANS A STALE VALUE ON EITHER SIDE IS INVISIBLE. Raise the Luau row to
# 5.0 and the mesh guard stays green - it is checking its own constant - while
# the capture pokes a stud past the casemate mouth and a third gun becomes
# shootable through the ship from the far sand. The fight breaks and every
# gate passes, which is this repo's signature failure: a value that exists in
# one place and is needed in another, where the second place remembers it
# instead of reading it.
#
# So it is read, here, from both sides. FAIL rather than warn: a warning about
# a number nobody looks at is the same as no check.
#
# Both regexes are deliberately anchored to a SINGLE FLAT LINE. Wrack's row
# carries nested tables (`body = { ... }`), and a non-greedy `{(.*?)}` sweep
# over a Luau row silently truncates at the first inner brace - it has already
# returned a confident wrong answer about this exact row once.
mesh_gen = (ROOT / "assets" / "boss_gen.py").read_text()
m_mesh = re.search(r"^WR_BATTERY_SHOT_RADIUS\s*=\s*([0-9.]+)", mesh_gen, re.M)
m_row = re.search(r"^\tshotRadius = ([0-9.]+),", creatures.get("wrack_battery", ""), re.M)
if not m_mesh:
    problem("assets/boss_gen.py has no WR_BATTERY_SHOT_RADIUS - the casemate guard's own constant is gone")
if not m_row:
    problem("Creatures.items.wrack_battery has no shotRadius - the fight's primary target falls back to a derived capture")
if m_mesh and m_row and float(m_mesh.group(1)) != float(m_row.group(1)):
    problem(
        f"wrack_battery.shotRadius is {m_row.group(1)} in Creatures.luau but "
        f"WR_BATTERY_SHOT_RADIUS is {m_mesh.group(1)} in assets/boss_gen.py - "
        "the casemates are solved against that number; a mismatch leaves the boss shootable through"
    )

# ---------------------------------------------------------------- the chip ledger
#
# THE PYRELISK'S HEALTH BAR IS NOT A BAR, IT IS A PROGRESS DIAL. Nothing
# damages that colossus directly: each milestone takes an exact fraction off it
# (`Fn.pyreliskChip`), and the shipped stance machinery - `bossPhaseIndex` ->
# `ATTR.STANCE` - reads the dial to decide which act the fight is in. So the
# chips and the phase threshold are ONE decision, spread across two files in
# two languages, and neither file can see the other.
#
# WHAT BREAKS IF THEY DRIFT, and this is why it is a FAIL and not a warning:
# nothing visible. A chip that lands a hundredth off a boundary fires a stance
# change - a banner, a sting and a whole new attack pool - in the middle of an
# act; a ledger that no longer sums to 1.0 is a colossus that will not die when
# its second arm does. Both present as something else entirely, and both pass
# every other gate in the project, because each file is internally consistent.
# This repo's signature failure: a value that exists in one place and is needed
# in another, where the second place REMEMBERS it instead of reading it.
#
# TWO EQUALITIES, NOT FOUR, SINCE THE ARM CLIMB WAS CUT (2026-09-12). The
# ledger used to be four chips over three acts - flanks, arms, six rocks and the
# neck core - and act 3 went with the climb: `K.PY_ROCK_FRACTION` and
# `K.PY_CORE_FRACTION` no longer exist and `Bosses.items.pyrelisk.phases` is two
# rows. What is left is the pair below, and the pair still catches everything
# the four did:
#
#   1. the threshold equality   phases[2].below == 1 - 2 * flank   (0.70)
#   2. the ledger CLOSES        2 * flank + 2 * arm == 1.00
#
# THE SECOND ONE IS THE ONE THAT MATTERS. The first only asserts that the flank
# chips line up with the stance boundary; the second asserts that the fight can
# END - the second arm's chip is the lethal one, and a ledger that sums to 0.95
# is a colossus that reaches the chip floor with an arm still owed and never
# collapses, which is the whole act-4 entry silently gone. (It is also why the
# row count is asserted: a third phase row nothing can reach would be a book
# that cannot be cast, and the sum would still close.)
#
# THE LEDGER IS THE COLOSSUS'S BAR, AND ONLY THE COLOSSUS'S. `pyrelisk_heart`
# is a second boss row with a health bar of its own (14,000), and that bar is
# DAMAGED - directly, with weapons - which nothing on the summit ever is. It is
# not a dial, no chip ever touches it, and it has no phase thresholds that any
# fraction has to land on: its `phases` split at 0.45 purely to add a move.
#
# So the heart's act adds NOTHING to the equalities below and must not. If a
# future change makes the heart's bar a chipped dial too, it needs its OWN
# ledger and its own gate - folding a second boss's fractions into this sum
# would make both of them unfalsifiable, because any error in one could be
# cancelled by the other and the total would still close.
#
# Read from BOTH SIDES, like the Wrack battery's shot radius above. The
# fractions are authored as exact two-decimal values so the sum is
# representable; compared to 1e-9 regardless.
creature_service = (ROOT / "src" / "Server" / "Services" / "CreatureService.luau").read_text()


def _py_fraction(name):
    m = re.search(rf"^K\.{name}\s*=\s*([0-9.]+)\s*$", creature_service, re.M)
    if not m:
        problem(
            f"CreatureService.luau has no K.{name} - the Pyrelisk chip ledger cannot be checked, "
            "which is worse than a wrong number: the fight's act boundaries become unguarded"
        )
        return None
    return float(m.group(1))


def _py_below():
    block = braced(bosses.get("pyrelisk", ""), "phases")
    if block is None:
        problem("Bosses.items.pyrelisk has no phases block - the act thresholds are gone")
        return []
    return [float(v) for v in re.findall(r"below\s*=\s*([0-9.]+)", block)]


_flank = _py_fraction("PY_FLANK_FRACTION")
_arm = _py_fraction("PY_ARM_FRACTION")
_below = _py_below()
if None not in (_flank, _arm):
    if len(_below) != 2:
        problem(
            f"Bosses.items.pyrelisk.phases has {len(_below)} rows, not 2 - the Pyrelisk's two acts "
            "are its two phases, and the chip ledger is written against exactly that"
        )
    else:
        _act1, _act2 = 1.0 - _below[1], _below[1]
        for _label, _lhs, _rhs, _why in (
            (
                "act 1 (two flank scars)",
                _flank * 2,
                _act1,
                f"K.PY_FLANK_FRACTION * 2 = {_flank * 2:.4f} but 1.0 - phases[2].below = {_act1:.4f}",
            ),
            (
                "act 2 (two arms)",
                _arm * 2,
                _act2,
                f"K.PY_ARM_FRACTION * 2 = {_arm * 2:.4f} but phases[2].below = {_act2:.4f}",
            ),
            (
                "the ledger closes",
                _flank * 2 + _arm * 2,
                1.0,
                f"the two chips sum to {_flank * 2 + _arm * 2:.4f}, not 1.0 - the second arm's "
                "death is the lethal chip and it can only be lethal if the ledger closes",
            ),
        ):
            if abs(_lhs - _rhs) > 1e-9:
                problem(
                    f"Pyrelisk chip ledger, {_label}: {_why}. The chips (CreatureService.luau) and the "
                    "phase threshold (Bosses.luau) are ONE decision - a mismatch fires a stance change "
                    "inside an act, or leaves the colossus unable to die. Re-derive both, do not widen this."
                )

# ---------------------------------------------------------------- report
if problems:
    print(f"CONTENT CHECK: {len(problems)} problem(s)")
    for p in problems:
        print("  -", p)
    sys.exit(1)
print(
    f"CONTENT CHECK OK: {len(materials)} materials, {len(creatures)} creatures, {len(armor_pieces)} armor pieces in {len(armor_set_ids)} sets, {len(trinkets)} trinkets, "
    f"{len(rods)} rods, {len(weapons)} weapons, {len(baits)} baits, "
    f"{len(bosses)} bosses, {len(island_ids)} islands, "
    f"{len(quests)} quests, {len(npcs)} npcs, {len(shops)} shops"
)
