# Rebuilding this harness if /tmp scratch was purged

Run is 24 s and deterministic, so rebuilding costs almost nothing.

1. `mkdir -p` this dir; `cp src/Shared/Config/MeshColors.luau before.luau`
2. Recreate `run_redirected.py`: import `gen_mesh_colors` from
   `/Users/samarthsreenivas/Developer/How-to-Fish/tools`, set
   `sys.dont_write_bytecode = True`, rebind `g.OUT` to a scratch path, clear
   `sys.argv[1:]`, call `g.main()`. Never let OUT point at the repo.
3. Recreate `diff_by_name.py` (row regex `^\t\["([^"]+)"\] = Color3\.fromRGB\((\d+), (\d+), (\d+)\),`)
   and group by lane prefix.
4. Re-derive `collider_skip.patch`: in the `DUMP` string in
   `tools/gen_mesh_colors.py`, immediately after
   `if obj.type != "MESH": continue`, add `if obj.name.endswith("Collider"): continue`
   plus the rationale comment citing the boss_gen Wrack handoff line.
5. `on_write.sh` order: patch tool -> re-baseline -> run redirected -> assert no
   Collider row -> write -> 4 gates -> re-diff.

Key facts to re-verify rather than trust:
- `gen_mesh_colors.py` has NO output flag; `OUT` is a module global (rebindable).
- `Wrack_HullCollider` is the ONLY Collider-suffixed Blender object; swamp trunk
  colliders are Luau-built at placement and unaffected.
- Islands report should read 360 objects / 360 rows / 0 missing.
