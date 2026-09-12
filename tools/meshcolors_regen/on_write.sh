#!/bin/zsh
# WRITE-time harness. DO NOT RUN until the USER says WRITE.
# No staging, no stashing, no commits -- working tree only.
set -u
S=/private/tmp/claude-501/-Users-samarthsreenivas-Developer-How-to-Fish/302b58b4-8d25-4b0f-84ce-b618f8159d02/scratchpad/meshcolors-regen
R=/Users/samarthsreenivas/Developer/How-to-Fish
M=$R/src/Shared/Config/MeshColors.luau
T=$R/tools/gen_mesh_colors.py
cd $R || exit 1

# 0. ASSERT the Collider skip rule. It is IN tools/gen_mesh_colors.py as of
#    regen #1, so this no longer patches - it fails loudly if the rule was
#    lost to a revert or a merge, because losing it silently re-adds the row
#    the Wrack lane asked to keep out.
grep -q 'endswith("Collider")' $T || { echo "!! Collider skip rule MISSING from $T"; exit 1; }
echo "== Collider skip rule present"

# 0b. ASSERT the tool probes every target the builder dispatches. `ARENAS` is
#     hand-maintained, and a sub-room target missing from it (pyrelisk_heart,
#     regen #2) costs that room every colour row with nothing else noticing.
python3 -c "
import re, sys
disp = set(re.findall(r'^    \"(\w+)\": build_', open('assets/arena_gen.py').read(), re.M))
tool = set(re.findall(r'^ARENAS = \[(.*)\]', open('tools/gen_mesh_colors.py').read(), re.M)[0].replace('\"','').split(', '))
miss = sorted(disp - tool)
sys.exit('!! arena targets missing from ARENAS: %s' % miss) if miss else print('== ARENAS covers all %d dispatched targets' % len(disp))
" || exit 1

# 1. RE-BASELINE: other lanes may have hand-edited MeshColors during the hold.
cp $M $S/before_at_write.luau
echo "== baseline md5 $(md5 -q $M)"
diff -q $S/before.luau $S/before_at_write.luau >/dev/null \
  && echo "== baseline unchanged since dry run" \
  || echo "== BASELINE MOVED since the dry run - the dry-run numbers are stale"

# 2. Re-run against THEN-CURRENT generators, still redirected to scratch.
python3 $S/run_redirected.py $S/after_at_write.luau || exit 1

# 3. Assert the Wrack decision held.
grep -q "Collider" $S/after_at_write.luau \
  && { echo "!! a Collider row is still being emitted"; exit 1; } \
  || echo "== no Collider row emitted (Wrack omission holds)"

# 4. Write the repo file.
cp $S/after_at_write.luau $M
echo "== wrote $M  md5 $(md5 -q $M)"

# 5. Gates.
echo "== stylua";        stylua --check src/Shared/Config/MeshColors.luau; echo "   rc=$?"
echo "== selene";        selene src;                                       echo "   rc=$?"
echo "== rojo";          rojo build default.project.json -o $S/build_check.rbxm;     echo "   rc=$?"
echo "== check_content"; python3 tools/check_content.py;                   echo "   rc=$?"

# 6. Re-diff by name against the re-baselined before.
python3 $S/diff_by_name.py $S/before_at_write.luau $S/after_at_write.luau > $S/diff_at_write.md
sed -n '1,60p' $S/diff_at_write.md
