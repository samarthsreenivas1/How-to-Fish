#!/usr/bin/env python3
"""Revert named rows in the repo MeshColors.luau to their before-values.

Usage: revert_rows.py <before.luau> <repo MeshColors.luau> <NamePrefix> [...]
A prefix matching no differing row is reported, not silently ignored -- the
whole point is that an objecting lane learns whether its rows actually moved.
Rows ADDED by the regeneration are deleted; rows CHANGED are restored; rows
REMOVED are re-inserted in sorted position.
"""
import re, sys

ROW = re.compile(r'^\t\["([^"]+)"\] = Color3\.fromRGB\((\d+), (\d+), (\d+)\),$')

def load(p):
    return {m.group(1): m.group(0) for m in
            (ROW.match(l.rstrip("\n")) for l in open(p)) if m}

before_p, target_p, prefixes = sys.argv[1], sys.argv[2], tuple(sys.argv[3:])
before, cur = load(before_p), load(target_p)

touched = {n for n in set(before) | set(cur)
           if before.get(n) != cur.get(n) and n.startswith(prefixes)}
if not touched:
    print("no differing rows match %r - nothing to revert" % (prefixes,)); raise SystemExit(0)

lines = open(target_p).read().split("\n")
out, seen = [], set()
for line in lines:
    m = ROW.match(line)
    if m and m.group(1) in touched:
        n = m.group(1); seen.add(n)
        if n in before:
            out.append(before[n]); print("restored %s" % n)
        else:
            print("deleted  %s (was added by regen)" % n)
        continue
    out.append(line)
for n in sorted(touched - seen):          # rows the regen removed
    row = before[n]
    for i, line in enumerate(out):
        m = ROW.match(line)
        if m and m.group(1) > n:
            out.insert(i, row); print("re-inserted %s" % n); break
open(target_p, "w").write("\n".join(out))
