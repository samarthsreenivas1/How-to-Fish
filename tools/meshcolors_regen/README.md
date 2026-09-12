# MeshColors regen harness (rescued from a session scratchpad 2026-09-12; untracked, durable)
One-shot, announced regeneration of src/Shared/Config/MeshColors.luau via tools/gen_mesh_colors.py
with a by-name before/after diff, determinism check, Collider-skip assertion and gates.
See REBUILD.md for the procedure; on_write.sh is the run. Blender takes ~22 s idle, ~220 s under fleet load.
