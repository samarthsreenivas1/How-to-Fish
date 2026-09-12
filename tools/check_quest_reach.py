#!/usr/bin/env python3
"""Can a quest objective actually be completed AT THE LEVEL ITS QUEST IS OFFERED?

check_content.py proves every id a quest names EXISTS. check_quest_objectives.py
proves two runtime-matcher traps are absent (a `waters` filter on a kill, a
species/waters contradiction). Neither asks the question that actually kills a
questline: the objective names only real things, matches the notify payload
perfectly, and still cannot be done by the player standing in front of the NPC.

Strictly, almost nothing is impossible at level 50 - so "reachable" here means
reachable at the quest's OFFER LEVEL:

    offerLevel(q) = max( q.requiresLevel or 1,
                         the level at which the giver can first be MET,
                         offerLevel of every quest in q's prereq chain )

The giver's level is the island's `unlockLevel` for a listed island, and for an
islet a BOAT computation (below). A quest whose objective needs content above
its own offerLevel is a dead end at the moment it is offered: the player takes
it and cannot touch it for another N levels, and the NPC never says why.

FAIL rules (any one exits 1):

  F1 kill/catch species - the species must be obtainable at offerLevel: its
     `waters` pool must be open (an island water needs that island's
     unlockLevel; "ocean" is always open), or it must appear in the ambient /
     raid roster of an island that is open, or be a boss.
  F2 catch waters - the water key must be a WATERS_BY_PART value, its island
     must be open at offerLevel, and it must hold at least one non-Boss row of
     the objective's `rarity` (an Uncommon filter on a water with no Uncommon
     rows can never fire).
  F3 craft - the itemId must be craftable and its recipe's own requiresLevel
     must be <= offerLevel (a craft objective you cannot legally craft is the
     same dead end), and every recipe material must be obtainable at offerLevel.
  F4 deliver - every material must be obtainable at offerLevel: dropped by a
     creature in an open pool/roster, or stocked by a shop on a reachable NPC.
  F5 visit - the island must exist; a listed island needs unlockLevel <=
     offerLevel; an islet needs its boat-reach level <= offerLevel.
  F6 runtime matching - kill objectives must not carry `waters`
     (QuestService.notify("kill") sends no waters, so the filter compares
     against nil forever); a species+waters pair must agree; `count` must be a
     positive integer where the type takes one; `repeatable` must be a value
     offersFor understands (true or "daily").
  F7 chain - `prereq` must exist, must not cycle, and requiresLevel must be
     non-decreasing along the chain.
  F8 stranded giver - the giver's island must be reachable: a listed island
     always is, and an islet must lie inside the seaworthiness of some place
     reachable at some level. An islet outside every circle cannot be sailed
     to, so its resident is never met and every quest they carry is never
     offered - the deadest dead end this file can find, and it hides behind
     zero other symptoms. Objectives on such a quest are still measured at
     MAX_LEVEL, so the one finding does not cascade into a wall of F-lines
     about a quest nobody can be offered at all. Islands.luau owns the fix
     (the islet's `worldPosition` AND its `spawn`, by the same delta).
     WAS A WARN until 2026-09-12, on the theory that another file owned it;
     two islets sat stranded for a fortnight because a WARN is something a
     gate run scrolls past. A finding nobody acts on is not a finding.

WARN rules (printed, never fatal - they are data other files own):

  W2 requiresLevel is below the level at which the giver can first be met (the
     gate is decoration - the island gate is the real one). W1 was the
     stranded giver and is F8 above now; the number is left in place so the
     older commit messages still resolve.

BOAT REACH (islets). An islet is never in Islands.order and has no
unlockLevel: the only way there is to sail, and BoatService's open-sea DoT
makes "sail" mean "stay inside your tier's `seaworthiness` of somewhere you may
enter" (WorldService.openSeaDistance subtracts the island's radius, so the
figure compared is centre-distance minus both radii). Tier 1 is granted when
island 1's boss falls, so its level is the requiresLevel of the bait whose
`summonsBoss` is that boss; tiers 2-6 use their recipe's requiresLevel. A
breadth-first walk from the islands open at level L, hopping through islets
(which are enterable, so they shelter too), gives the first level each islet is
reachable at.

Usage:

    python3 tools/check_quest_reach.py                 # exits 1 on any FAIL
    python3 tools/check_quest_reach.py --quests PATH   # check a copy instead
    python3 tools/check_quest_reach.py --self-test     # positive control

--self-test is the control this file is not evidence without: it writes
deliberately broken copies of Quests.luau (and, for F8, of Islands.luau) to a
temp dir, asserts each one FAILS with the rule it was built to trip (and that
the injection anchor was actually found, so a control that silently did nothing
cannot pass), and asserts the real files PASS.
"""

import argparse
import math
import pathlib
import re
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
SRC = ROOT / "src" / "Shared"


# ---------------------------------------------------------------- helpers
# Lifted from tools/check_content.py: the data files are stylua-formatted, so
# conservative regexes plus a brace walk are enough. This is not a Luau parser.


def read(rel):
    return (SRC / rel).read_text()


def strip_comments(text):
    """Drop Luau line comments. Quests.luau's own header documents a payload as
    `{ player, species, rarity }` INSIDE a comment and writes `repeatable =
    "daily"` in prose - both of which a brace walk or a field regex would read
    as data. Comments are stripped from the quest rows before anything is
    scanned; string literals are respected so a `--` inside one survives."""
    out = []
    for line in text.splitlines():
        in_string, cut = False, None
        i = 0
        while i < len(line):
            ch = line[i]
            if ch == '"' and (i == 0 or line[i - 1] != "\\"):
                in_string = not in_string
            elif ch == "-" and not in_string and line[i : i + 2] == "--":
                cut = i
                break
            i += 1
        out.append(line if cut is None else line[:cut])
    return "\n".join(out)


def blocks(text, table="items"):
    """id -> the row's source text (to the next row or EOF)."""
    out = {}
    matches = list(re.finditer(rf"\.{table}\.([A-Za-z_][A-Za-z0-9_]*)\s*=\s*{{", text))
    for i, m in enumerate(matches):
        end = matches[i + 1].start() if i + 1 < len(matches) else len(text)
        out[m.group(1)] = text[m.start() : end]
    return out


def braced(block, field):
    """The `{...}` body after `field = ` inside a row (brace-matched)."""
    m = re.search(rf"\b{field}\s*=\s*{{", block)
    if not m:
        return None
    depth, i = 1, m.end()
    while i < len(block) and depth:
        depth += {"{": 1, "}": -1}.get(block[i], 0)
        i += 1
    return block[m.end() : i - 1]


def entries(text):
    """Each top-level `{...}` inside a Luau list, brace-matched."""
    out, depth, start = [], 0, None
    for i, ch in enumerate(text or ""):
        if ch == "{":
            if depth == 0:
                start = i
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0 and start is not None:
                out.append(text[start + 1 : i])
                start = None
    return out


def literal_table(text, name):
    """id -> row text for a table written as ONE literal (`Islands.items = {`)."""
    m = re.search(rf"{name}\s*=\s*{{(.*)^}}", text, re.S | re.M)
    if not m:
        return {}
    body, out = m.group(1), {}
    heads = list(re.finditer(r"^\t([A-Za-z_][A-Za-z0-9_]*)\s*=\s*{", body, re.M))
    for i, h in enumerate(heads):
        end = heads[i + 1].start() if i + 1 < len(heads) else len(body)
        out[h.group(1)] = body[h.start() : end]
    return out


def num(block, field):
    m = re.search(rf"\b{field}\s*=\s*(-?[\d.]+)", block or "")
    return float(m.group(1)) if m else None


def sval(block, field):
    m = re.search(rf'\b{field}\s*=\s*"([^"]*)"', block or "")
    return m.group(1) if m else None


def vector3(block, field):
    m = re.search(rf"\b{field}\s*=\s*Vector3\.new\(\s*(-?[\d.]+)\s*,\s*(-?[\d.]+)\s*,\s*(-?[\d.]+)", block or "")
    return (float(m.group(1)), float(m.group(3))) if m else None


def mat_counts(body):
    """`{ kelp_fiber = 6, pearl = 2 }` -> {kelp_fiber: 6, pearl: 2}."""
    return {k: int(v) for k, v in re.findall(r"([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(\d+)", body or "")}


# ---------------------------------------------------------------- load
def load(quests_path, islands_path=None):
    d = {}
    d["quests"] = blocks(strip_comments(pathlib.Path(quests_path).read_text()))
    d["creatures"] = blocks(read("Data/Creatures.luau"))
    d["npcs"] = blocks(read("Data/Npcs.luau"))
    d["materials"] = set(blocks(read("Data/Materials.luau")))
    d["shops"] = blocks(read("Data/Shops.luau"))
    d["bait"] = blocks(read("Data/Bait.luau"))
    world = read("Config/World.luau")
    islands_text = pathlib.Path(islands_path).read_text() if islands_path else read("Config/Islands.luau")
    boats_text = read("Data/Boats.luau")

    d["ocean"] = sval(world, "WATERS_OCEAN") or "ocean"
    wbp = braced(world, "WATERS_BY_PART") or ""
    d["waters_keys"] = set(re.findall(r'=\s*"([a-z_]+)"', wbp)) | {d["ocean"]}

    d["islands"] = literal_table(islands_text, r"Islands\.items")
    d["order"] = re.findall(r'"([a-z_]+)"', re.search(r"Islands\.order\s*=\s*{([^}]*)}", islands_text).group(1))
    d["boats"] = literal_table(boats_text, r"Boats\.items")

    # craftables: anything CraftingService can build, with its recipe level.
    d["recipes"] = {}
    for rel, table in (
        ("Data/Rods.luau", r"Rods\.items"),
        ("Data/Weapons.luau", r"Weapons\.items"),
        ("Data/Armor.luau", r"Armor\.items"),
        ("Data/Trinkets.luau", r"Trinkets\.items"),
    ):
        for rid, block in blocks(read(rel)).items():
            recipe = braced(block, "recipe")
            d["recipes"][rid] = (
                int(num(recipe, "requiresLevel") or 0) if recipe else None,
                mat_counts(braced(recipe, "materials")) if recipe else {},
            )
    for rid, block in list(d["boats"].items()) + list(d["bait"].items()):
        recipe = braced(block, "recipe")
        d["recipes"][rid] = (
            int(num(recipe, "requiresLevel") or 0) if recipe else None,
            mat_counts(braced(recipe, "materials")) if recipe else {},
        )
    return d


# ---------------------------------------------------------------- world model
class World:
    def __init__(self, d):
        self.d = d
        self.max_level = 50
        # Class-level, and deliberately reset here: self_test builds several
        # Worlds in one process, and once a control can move an ISLAND the
        # stale cache would answer for the previous world's map - a control
        # that silently measures the wrong file passes for the wrong reason.
        World._islet_cache = None
        # waters key -> the island whose interior water it is. Every key in
        # WATERS_BY_PART except the ocean is an island id today; a key that is
        # not is reported rather than silently treated as open.
        self.water_island = {k: k for k in d["waters_keys"] if k in d["islands"]}
        self.unknown_waters = {k for k in d["waters_keys"] if k != d["ocean"] and k not in self.water_island}

        self.unlock = {}
        for iid, block in d["islands"].items():
            self.unlock[iid] = int(num(block, "unlockLevel")) if num(block, "unlockLevel") is not None else None

        # species -> (rarity, waters, is_boss)
        self.species = {}
        for cid, block in d["creatures"].items():
            self.species[cid] = (
                sval(block, "rarity") or "?",
                sval(block, "waters") or d["ocean"],
                bool(sval(block, "boss")) or sval(block, "rarity") == "Boss",
            )

        # species -> islands whose ambient/raid roster lists it (a land spawn
        # needs no water at all).
        self.roster_islands = {}
        for iid, block in d["islands"].items():
            listed = set()
            for field in ("ambient", "raid"):
                body = braced(block, field)
                if body:
                    listed |= set(re.findall(r'id = "([a-z_]+)"', body))
            for sid in listed:
                self.roster_islands.setdefault(sid, set()).add(iid)

        # material -> the levels at which it becomes obtainable (min wins).
        self.material_level = {}
        for cid, block in d["creatures"].items():
            drops = braced(braced(block, "drops") or "", "materials")
            if not drops:
                continue
            for mid in re.findall(r"([A-Za-z_][A-Za-z0-9_]*)\s*=\s*{", drops):
                lvl = self.species_level(cid)
                if lvl is not None:
                    self.material_level[mid] = min(self.material_level.get(mid, 10**6), lvl)
        for nid, block in d["npcs"].items():
            shop = sval(block, "shop")
            if not shop or shop not in d["shops"]:
                continue
            lvl = self.npc_level(nid)
            if lvl is None:
                continue
            for slot in re.finditer(r'kind = "material", id = "([a-z_]+)"', d["shops"][shop]):
                mid = slot.group(1)
                self.material_level[mid] = min(self.material_level.get(mid, 10**6), lvl)

    # ---- levels
    def water_level(self, waters):
        """Level at which casts into this water are possible, or None."""
        if waters == self.d["ocean"]:
            return 1
        iid = self.water_island.get(waters)
        if iid is None:
            return None
        return self.unlock.get(iid) if self.unlock.get(iid) is not None else self.islet_level(iid)

    def species_level(self, sid):
        """Lowest level the species can be fought at, or None if nowhere."""
        row = self.species.get(sid)
        if not row:
            return None
        rarity, waters, is_boss = row
        best = None
        if not is_boss:
            wl = self.water_level(waters)
            if wl is not None:
                best = wl
        for iid in self.roster_islands.get(sid, ()):
            lvl = self.unlock.get(iid)
            if lvl is None:
                lvl = self.islet_level(iid)
            if lvl is not None:
                best = lvl if best is None else min(best, lvl)
        if is_boss and best is None:
            # A boss row is spawned by its call bait, not rolled - its water
            # gate still applies, so fall back to that.
            wl = self.water_level(waters)
            best = wl
        return best

    def rarities_in(self, waters):
        return {r for _, (r, w, b) in self.species.items() if w == waters and not b}

    # ---- boats / islets
    def tier_levels(self):
        """boat tier -> the level it can first be owned at."""
        out = {}
        first_boss = sval(self.d["islands"][self.d["order"][0]], "boss")
        granted = 1
        for _, block in self.d["bait"].items():
            if sval(braced(block, "effect") or "", "summonsBoss") == first_boss:
                recipe = braced(block, "recipe")
                granted = int(num(recipe, "requiresLevel") or 1)
        for bid, block in self.d["boats"].items():
            tier = int(num(block, "tier"))
            recipe = braced(block, "recipe")
            out[tier] = granted if not recipe else int(num(recipe, "requiresLevel") or 1)
        return out

    def seaworthiness_at(self, level):
        tiers = self.tier_levels()
        best = 0
        for bid, block in self.d["boats"].items():
            tier = int(num(block, "tier"))
            if tiers.get(tier, 10**6) <= level:
                best = max(best, num(block, "seaworthiness") or 0)
        return best

    def _geo(self, iid):
        block = self.d["islands"][iid]
        xz = vector3(block, "worldPosition")
        return xz, num(block, "radius") or 0

    def gap(self, a, b):
        (ax, az), ar = self._geo(a)
        (bx, bz), br = self._geo(b)
        return math.dist((ax, az), (bx, bz)) - ar - br

    def reachable_at(self, level):
        """Every island/islet a player of `level` can stand on."""
        sw = self.seaworthiness_at(level)
        seen = {i for i, u in self.unlock.items() if u is not None and u <= level}
        # A site (the Maelstrom) also needs every heart; unlockLevel is the
        # honest floor and this tool never claims more than a floor.
        frontier = list(seen)
        if sw <= 0:
            return seen
        while frontier:
            a = frontier.pop()
            for b in self.d["islands"]:
                if b in seen:
                    continue
                u = self.unlock.get(b)
                if u is not None and u > level:
                    continue
                if self.gap(a, b) <= sw:
                    seen.add(b)
                    frontier.append(b)
        return seen

    _islet_cache = None

    def islet_level(self, iid):
        if World._islet_cache is None:
            World._islet_cache = {}
            for level in range(1, self.max_level + 1):
                for i in self.reachable_at(level):
                    World._islet_cache.setdefault(i, level)
        return World._islet_cache.get(iid)

    def npc_level(self, nid):
        island = sval(self.d["npcs"].get(nid, ""), "island")
        if island is None or island not in self.d["islands"]:
            return None
        u = self.unlock.get(island)
        return u if u is not None else self.islet_level(island)

    def material_at(self, mid, level):
        lvl = self.material_level.get(mid)
        return lvl is not None and lvl <= level


# ---------------------------------------------------------------- checks
def check(quests_path, islands_path=None):
    d = load(quests_path, islands_path)
    w = World(d)
    fails, warns = [], []

    for key in sorted(w.unknown_waters):
        warns.append(f"waters key '{key}' in WATERS_BY_PART matches no island - reachability unknowable")

    quests = d["quests"]
    # An ABSENT requiresLevel is not level 1: offersFor simply applies no level
    # gate, so the prereq is the whole gate. Kept as None so the non-decreasing
    # chain rule below only compares gates that were actually written down.
    level_of = {qid: (int(num(b, "requiresLevel")) if num(b, "requiresLevel") is not None else None) for qid, b in quests.items()}
    giver_of = {qid: sval(b, "giver") for qid, b in quests.items()}
    prereq_of = {qid: sval(b, "prereq") for qid, b in quests.items()}

    # F7 / W1 / W2: chains, givers, and the offer level.
    unreachable_giver = set()
    for qid, giver in giver_of.items():
        lvl = w.npc_level(giver) if giver else None
        if giver and giver in d["npcs"] and lvl is None:
            unreachable_giver.add(qid)
            fails.append(
                f"{qid}: giver '{giver}' is on '{sval(d['npcs'][giver], 'island')}', which no boat tier can "
                f"reach inside its seaworthiness at any level - the quest can never be offered (fix the islet's "
                f"worldPosition AND its spawn, by the same delta, in Islands.luau)"
            )
        elif lvl is not None and level_of[qid] is not None and level_of[qid] < lvl:
            warns.append(
                f"{qid}: requiresLevel {level_of[qid]} is below the level its giver can first be met at (L{lvl}) - "
                f"the level gate is decoration"
            )

    def offer_level(qid, seen=None):
        seen = seen or set()
        if qid in seen:
            return level_of.get(qid) or 1
        seen = seen | {qid}
        if qid in unreachable_giver:
            return w.max_level
        lvl = level_of.get(qid) or 1
        giver_lvl = w.npc_level(giver_of.get(qid) or "")
        if giver_lvl is not None:
            lvl = max(lvl, giver_lvl)
        prereq = prereq_of.get(qid)
        if prereq in quests:
            lvl = max(lvl, offer_level(prereq, seen))
        return lvl

    for qid, prereq in prereq_of.items():
        if prereq is None:
            continue
        if prereq not in quests:
            fails.append(f"{qid}: prereq '{prereq}' is not a quest")
            continue
        chain, cur = [], prereq
        while cur in quests and cur not in chain:
            chain.append(cur)
            cur = prereq_of.get(cur)
        if cur is not None and cur in chain:
            fails.append(f"{qid}: prereq chain cycles through '{cur}'")
        if level_of[prereq] is not None and level_of[qid] is not None and level_of[prereq] > level_of[qid]:
            fails.append(
                f"{qid}: requiresLevel {level_of[qid]} is BELOW its prereq '{prereq}' ({level_of[prereq]}) - "
                f"a chain's levels must not decrease"
            )

    # F6: repeatable values offersFor understands.
    for qid, block in quests.items():
        m = re.search(r"\brepeatable\s*=\s*([^,\n]+)", block)
        if m and m.group(1).strip().strip('"') not in ("true", "daily"):
            fails.append(f"{qid}: repeatable = {m.group(1).strip()} - offersFor only understands true or \"daily\"")

    # the objectives themselves
    for qid in sorted(quests):
        block = quests[qid]
        lvl = offer_level(qid)
        objectives = braced(block, "objectives")
        if not objectives:
            fails.append(f"{qid}: no objectives")
            continue
        for i, obj in enumerate(entries(objectives), 1):
            tag = f"{qid} objective {i}"
            kind = sval(obj, "type")
            count = num(obj, "count")
            species = sval(obj, "species")
            rarity = sval(obj, "rarity")
            waters = sval(obj, "waters")
            if kind in ("catch", "kill") and count is not None and count < 1:
                fails.append(f"{tag}: count = {count:g} can never be reached")

            if kind == "kill":
                if waters:
                    fails.append(
                        f"{tag}: kill filters waters='{waters}', but notify(\"kill\") sends no waters - "
                        f"the filter compares against nil forever"
                    )
                if species:
                    slvl = w.species_level(species)
                    if slvl is None:
                        fails.append(f"{tag}: species '{species}' is in no open water and no island roster")
                    elif slvl > lvl:
                        _, sw_, _ = w.species[species]
                        fails.append(
                            f"{tag}: kill '{species}' first becomes available at L{slvl} (waters '{sw_}'), "
                            f"but the quest is offered at L{lvl}"
                        )
            elif kind == "catch":
                if waters and waters not in d["waters_keys"]:
                    fails.append(f"{tag}: waters '{waters}' is no WATERS_BY_PART surface")
                elif waters:
                    wl = w.water_level(waters)
                    if wl is None:
                        fails.append(f"{tag}: waters '{waters}' belongs to no reachable place")
                    elif wl > lvl:
                        fails.append(
                            f"{tag}: waters '{waters}' opens at L{wl} but the quest is offered at L{lvl}"
                        )
                    elif rarity and rarity not in w.rarities_in(waters):
                        fails.append(f"{tag}: waters '{waters}' holds no non-Boss row of rarity '{rarity}'")
                if species:
                    s = w.species.get(species)
                    if not s:
                        fails.append(f"{tag}: species '{species}' is not a creature")
                    else:
                        if waters and s[1] != waters:
                            fails.append(
                                f"{tag}: wants '{species}' in waters='{waters}', but that row only rolls in "
                                f"'{s[1]}' - no cast can produce it"
                            )
                        slvl = w.species_level(species)
                        if slvl is not None and slvl > lvl:
                            fails.append(
                                f"{tag}: catch '{species}' opens at L{slvl} but the quest is offered at L{lvl}"
                            )
            elif kind == "craft":
                item = sval(obj, "itemId")
                if item not in d["recipes"]:
                    fails.append(f"{tag}: craft itemId '{item}' is not craftable")
                else:
                    need, mats = d["recipes"][item]
                    if need is None:
                        fails.append(f"{tag}: craft '{item}' has no recipe - CraftingService can never build it")
                    else:
                        if need > lvl:
                            fails.append(
                                f"{tag}: crafting '{item}' needs L{need} but the quest is offered at L{lvl}"
                            )
                        for mid in mats:
                            if not w.material_at(mid, max(lvl, need)):
                                fails.append(
                                    f"{tag}: craft '{item}' needs material '{mid}', which nothing reachable at "
                                    f"L{max(lvl, need)} drops or sells"
                                )
            elif kind == "deliver":
                mats = mat_counts(braced(obj, "materials"))
                if not mats:
                    fails.append(f"{tag}: deliver has no materials")
                for mid, n in mats.items():
                    if mid not in d["materials"]:
                        fails.append(f"{tag}: deliver wants unknown material '{mid}'")
                    elif not w.material_at(mid, lvl):
                        where = w.material_level.get(mid)
                        fails.append(
                            f"{tag}: deliver wants {n} x '{mid}', first obtainable at "
                            f"{'L' + str(where) if where else 'nowhere'}, but the quest is offered at L{lvl}"
                        )
            elif kind == "visit":
                island = sval(obj, "island")
                if island not in d["islands"]:
                    fails.append(f"{tag}: visit island '{island}' is not in Islands.items")
                else:
                    u = w.unlock.get(island)
                    if u is not None:
                        if u > lvl:
                            fails.append(
                                f"{tag}: visit '{island}' needs L{u} (unlockLevel) but the quest is offered at L{lvl}"
                            )
                    else:
                        il = w.islet_level(island)
                        if il is None:
                            fails.append(f"{tag}: visit islet '{island}' is outside every seaworthiness circle")
                        elif il > lvl:
                            fails.append(
                                f"{tag}: visit islet '{island}' is first sailable at L{il} but the quest is "
                                f"offered at L{lvl}"
                            )
            else:
                fails.append(f"{tag}: type '{kind}' has no matcher in QuestService")

    return fails, warns, len(quests)


# ---------------------------------------------------------------- control
BREAKAGES = [
    # (anchor that must exist, replacement, what it proves)
    (
        '{ type = "catch", count = 5 },',
        '{ type = "catch", count = 5, waters = "maelstrom" },',
        "F2 - an L43 water on the tutorial quest",
    ),
    (
        '{ type = "kill", count = 5, species = "mire_leech" }',
        '{ type = "kill", count = 5, species = "mire_leech", waters = "swamp" }',
        "F6 - a waters filter on a kill",
    ),
    (
        '{ type = "craft", itemId = "bamboo_rod" }',
        '{ type = "craft", itemId = "krakenheart_rod" }',
        "F3 - a craft above the quest's level",
    ),
    (
        # NOT the_long_way_round: it is the quest F8's own control strands, and
        # a stranded giver's offer level is MAX_LEVEL, so nothing at all is
        # above it - which is precisely the blind spot the MAX_LEVEL fallback
        # buys, and a control must not be written over it.
        '{ type = "deliver", materials = { kelp_fiber = 6 } },\n\t\t{ type = "visit", island = "swamp" },',
        '{ type = "deliver", materials = { kelp_fiber = 6 } },\n\t\t{ type = "visit", island = "maelstrom" },',
        "F5 - a visit to a later island's gate",
    ),
]


# F8's control lives in Islands.luau, not Quests.luau: the only way to strand a
# giver is to move the islet they stand on. The Ferryman's raft is pushed to the
# far corner of the sea, where nothing shelters it at any tier.
ISLAND_BREAKAGE = (
    'worldPosition = Vector3.new(6800, 0, 8300),',
    'worldPosition = Vector3.new(30000, 0, 30000),',
    "F8 - an islet outside every seaworthiness circle",
    "the_long_way_round",
)


def self_test():
    real = SRC / "Data" / "Quests.luau"
    source = real.read_text()
    ok = True
    fails, warns, n = check(real)
    print(f"control 0: the real Quests.luau ({n} quests) ... ", end="")
    if fails:
        print("UNEXPECTED FAIL")
        for f in fails:
            print("   ", f)
        ok = False
    else:
        print("passes")
    with tempfile.TemporaryDirectory() as tmp:
        for i, (anchor, replacement, why) in enumerate(BREAKAGES, 1):
            print(f"control {i}: {why} ... ", end="")
            if source.count(anchor) != 1:
                print(f"BROKEN CONTROL - anchor appears {source.count(anchor)} times, expected 1")
                ok = False
                continue
            path = pathlib.Path(tmp) / f"Broken{i}.luau"
            path.write_text(source.replace(anchor, replacement))
            bad, _, _ = check(path)
            if bad:
                print(f"fails as intended ({bad[0]})")
            else:
                print("DID NOT FAIL - the rule is not wired")
                ok = False

        anchor, replacement, why, expect = ISLAND_BREAKAGE
        islands = SRC / "Config" / "Islands.luau"
        island_source = islands.read_text()
        print(f"control {len(BREAKAGES) + 1}: {why} ... ", end="")
        if island_source.count(anchor) != 1:
            print(f"BROKEN CONTROL - anchor appears {island_source.count(anchor)} times, expected 1")
            ok = False
        else:
            path = pathlib.Path(tmp) / "BrokenIslands.luau"
            path.write_text(island_source.replace(anchor, replacement))
            bad, _, _ = check(real, path)
            hit = [f for f in bad if f.startswith(expect + ":") and "no boat tier can" in f]
            if hit:
                print(f"fails as intended ({hit[0]})")
            else:
                print("DID NOT FAIL - the rule is not wired")
                ok = False
    return ok


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--quests", default=str(SRC / "Data" / "Quests.luau"))
    ap.add_argument("--islands", default=None, help="check a copy of Islands.luau instead (F8's control)")
    ap.add_argument("--self-test", action="store_true")
    args = ap.parse_args()

    if args.self_test:
        sys.exit(0 if self_test() else 1)

    fails, warns, n = check(args.quests, args.islands)
    for warning in warns:
        print("WARN:", warning)
    for f in fails:
        print("UNREACHABLE:", f)
    if fails:
        print(f"\n{len(fails)} unreachable objective(s) across {n} quests")
        sys.exit(1)
    print(f"QUEST REACH OK: {n} quests, every objective completable at its offer level ({len(warns)} warning(s))")


if __name__ == "__main__":
    main()
