#!/usr/bin/env python3
"""BY-NAME diff of two MeshColors.luau files, grouped by lane prefix."""
import re, sys, collections

ROW = re.compile(r'^\t\["([^"]+)"\] = Color3\.fromRGB\((\d+), (\d+), (\d+)\),')

def load(p):
    d = {}
    for line in open(p):
        m = ROW.match(line)
        if m:
            d[m.group(1)] = (int(m.group(2)), int(m.group(3)), int(m.group(4)))
    return d

# ordered: first matching prefix tuple wins
# Match on the BARE boss name, not an enumerated list of suffixes. The
# enumerated version silently mis-filed a whole sub-pack: the Pyrelisk lane
# added `PyreliskHeart_*` in regen #2, which matched neither "Pyrelisk_" nor
# "PyreliskArena_" and so landed under "other" - 22 rows reported in the one
# bucket nobody reads as belonging to a lane. A lane's rows must sort to that
# lane the first time a new sub-pack appears, without anyone editing this.
LANES = [
    ("Wrack",      ("Wrack",)),
    ("Pyrelisk",   ("Pyrelisk",)),
    ("Kraken",     ("Kraken",)),
    ("Noctyss",    ("Noctyss",)),
    ("Rimefang",   ("Rimefang",)),
    ("Brinejaw",   ("Brinejaw",)),
    ("Gnashroot",  ("Gnashroot",)),
]
ISLANDS = ("Island", "Islet", "Wreckwater", "Gloomtrench", "Maelstrom", "Volcano",
           "Swamp", "Ice", "Anchorage", "Bellbuoy", "Boilshoal", "Chapel",
           "Ferryraft", "Lampwork", "Loadstone", "Rookery", "Whalefall")

def lane(name):
    for label, prefixes in LANES:
        if name.startswith(prefixes):
            return label
    if name.startswith(ISLANDS):
        return "island/islet"
    return "other"

def rgb(t):
    return "fromRGB(%d, %d, %d)" % t

before, after = load(sys.argv[1]), load(sys.argv[2])
added   = sorted(set(after) - set(before))
removed = sorted(set(before) - set(after))
changed = sorted(n for n in set(before) & set(after) if before[n] != after[n])

buckets = collections.defaultdict(lambda: {"added": [], "removed": [], "changed": []})
for n in added:   buckets[lane(n)]["added"].append(n)
for n in removed: buckets[lane(n)]["removed"].append(n)
for n in changed: buckets[lane(n)]["changed"].append(n)

out = []
out.append("# MeshColors regeneration - by-name diff (dry run)\n")
out.append("`before.luau` = repo `src/Shared/Config/MeshColors.luau` at snapshot time")
out.append("`after.luau`  = `tools/gen_mesh_colors.py` output, OUT redirected to scratch\n")
out.append("| | rows |")
out.append("|---|---|")
out.append("| before | %d |" % len(before))
out.append("| after  | %d |" % len(after))
out.append("| added   | %d |" % len(added))
out.append("| removed | %d |" % len(removed))
out.append("| changed | %d |" % len(changed))
out.append("")

order = [l for l, _ in LANES] + ["island/islet", "other"]
for label in order:
    b = buckets.get(label)
    if not b or not any(b.values()):
        out.append("## %s\n\nno change\n" % label)
        continue
    out.append("## %s\n" % label)
    if b["added"]:
        out.append("**added (%d)**\n" % len(b["added"]))
        out.append("| name | colour |")
        out.append("|---|---|")
        for n in b["added"]:
            out.append("| `%s` | %s |" % (n, rgb(after[n])))
        out.append("")
    if b["removed"]:
        out.append("**removed (%d)**\n" % len(b["removed"]))
        out.append("| name | colour (was) |")
        out.append("|---|---|")
        for n in b["removed"]:
            out.append("| `%s` | %s |" % (n, rgb(before[n])))
        out.append("")
    if b["changed"]:
        out.append("**changed (%d)**\n" % len(b["changed"]))
        out.append("| name | old | new |")
        out.append("|---|---|---|")
        for n in b["changed"]:
            out.append("| `%s` | %s | %s |" % (n, rgb(before[n]), rgb(after[n])))
        out.append("")

print("\n".join(out))
