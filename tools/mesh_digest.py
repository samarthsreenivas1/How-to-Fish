#!/usr/bin/env python3
"""Per-object geometry digests for a .glb — the exact "did my edit move
someone else's mesh?" check.

WHY THIS EXISTS (2026-08-29). Several lanes now share the asset generators
(arena_gen.py, boss_gen.py, armor_gen.py), so a plausible-looking edit in one
lane can silently move another lane's geometry — it happened: a global
string replace hit `build_bj_foam` instead of `build_gn_foam` and the two
arenas swapped surf rings. Two checks were tried before this one and BOTH
are unsound:

  * Comparing exported .glb or rendered .png bytes. Measured on Blender
    5.2.0 LTS: two consecutive builds of identical sources produce different
    file hashes while the GEOMETRY is unchanged, so byte comparison is a
    false-positive generator. (The container's byte layout varies; the
    meshes do not.)
  * Diffing the exporter's per-object bbox lines. Sound as far as it goes,
    and version-proof — but it only sees an object's OUTER EXTENT. Measured:
    moving the foam ring's OUTER radius 86 -> 88 moves the bbox and is
    caught; moving its INNER radius 80 -> 82 does not move the bbox at all
    and passes silently. That inner radius is precisely the parameter the
    real accident changed, so bbox-diffing would have called the broken
    state clean.

This reads the actual vertex positions out of the glb and hashes them per
object, so it catches any change to any vertex, inner or outer, while
ignoring the container churn that makes byte comparison useless.

USAGE — build the same target at two revisions, then diff the digests:

    blender --background --python <arena_gen.py at rev A> -- /tmp/a.glb brinejaw
    blender --background --python assets/arena_gen.py            -- /tmp/b.glb brinejaw
    python3 tools/mesh_digest.py /tmp/a.glb > /tmp/a.txt
    python3 tools/mesh_digest.py /tmp/b.glb > /tmp/b.txt
    diff /tmp/a.txt /tmp/b.txt

KEEP A POSITIVE CONTROL. An empty diff means nothing until you have shown
the instrument can produce a non-empty one: perturb something harmless in
your own builder, confirm the diff fires, revert, re-run. A typo'd path or a
grep that matches nothing reads exactly like success otherwise. Pass
--self-test to see the digest of a file against itself (which must be empty)
— that only proves the reader works, not that your invocation was right.
"""

import hashlib
import json
import struct
import sys

# glTF component types -> (struct code, byte width)
_COMPONENTS = {
    5120: ("b", 1),
    5121: ("B", 1),
    5122: ("h", 2),
    5123: ("H", 2),
    5125: ("I", 4),
    5126: ("f", 4),
}
_COUNTS = {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4, "MAT4": 16}


def read_glb(path):
    """Return (gltf_json, binary_chunk)."""
    with open(path, "rb") as handle:
        data = handle.read()
    if data[:4] != b"glTF":
        raise SystemExit("%s is not a .glb" % path)
    total = struct.unpack_from("<I", data, 8)[0]
    offset, gltf, binary = 12, None, b""
    while offset < min(total, len(data)):
        length, kind = struct.unpack_from("<II", data, offset)
        chunk = data[offset + 8 : offset + 8 + length]
        if kind == 0x4E4F534A:  # JSON
            gltf = json.loads(chunk.decode("utf-8"))
        elif kind == 0x004E4942:  # BIN
            binary = chunk
        offset += 8 + length + (-length % 4)
    if gltf is None:
        raise SystemExit("%s has no JSON chunk" % path)
    return gltf, binary


def accessor_values(gltf, binary, index):
    """Decode one accessor into a flat list of numbers."""
    accessor = gltf["accessors"][index]
    code, width = _COMPONENTS[accessor["componentType"]]
    per = _COUNTS[accessor["type"]]
    count = accessor["count"]
    view = gltf["bufferViews"][accessor["bufferView"]]
    base = view.get("byteOffset", 0) + accessor.get("byteOffset", 0)
    stride = view.get("byteStride") or per * width
    out = []
    for i in range(count):
        start = base + i * stride
        out.extend(struct.unpack_from("<" + code * per, binary, start))
    return out


def digests(path, places=3):
    """(object name, vertex count, digest) per mesh, sorted by name.

    Positions are rounded before hashing so the digest tracks GEOMETRY and
    not float noise; sorting by name means a change in export order alone
    never shows up as a difference.
    """
    gltf, binary = read_glb(path)
    rows = []
    meshes = gltf.get("meshes", [])
    # Prefer the node name: that is the object name the generators print.
    names = {}
    for node in gltf.get("nodes", []):
        if "mesh" in node:
            names.setdefault(node["mesh"], node.get("name"))
    for index, mesh in enumerate(meshes):
        name = names.get(index) or mesh.get("name") or "mesh%d" % index
        digest = hashlib.sha256()
        total = 0
        for primitive in mesh.get("primitives", []):
            position = primitive.get("attributes", {}).get("POSITION")
            if position is None:
                continue
            values = accessor_values(gltf, binary, position)
            total += len(values) // 3
            for value in values:
                digest.update(("%.*f;" % (places, value)).encode("ascii"))
        rows.append((name, total, digest.hexdigest()[:16]))
    rows.sort()
    return rows


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    if not args:
        print(__doc__)
        raise SystemExit(2)
    for path in args:
        for name, count, digest in digests(path):
            print("%-40s %6d verts  %s" % (name, count, digest))


if __name__ == "__main__":
    main()
