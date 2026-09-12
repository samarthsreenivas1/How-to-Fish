"""bundle_gen.py - merge the 22 importable .glb files into 3 Studio bundles.

WHY
Every mesh in this game reaches Roblox through Studio's 3D importer, one
file at a time, and docs/import-checklist.md lists 24 rows across 22 files.
That is 22 trips through the Import dialog, 22 chances to mis-click a
setting, and 22 groups to rename and re-parent by hand. Nothing about the
meshes needs it: they are all authored at final size in the same units, none
of them wants a different importer-dialog setting from any other, and the
only reason they are separate files is that they are written by separate
generator scripts.

So this script re-packs them. It imports each source .glb, wraps that file's
top-level objects under a new Empty named EXACTLY the pack name the game
looks up under `ReplicatedStorage.Assets` (`IslandPack`, `WrackArena`, ...),
and exports the lot as three bundles under `assets/bundles/`. One Studio
import per bundle, then `tools/studio_import_bundles.lua` splits each
bundle's top-level children back out under `Assets` - producing the IDENTICAL
`Assets` tree the 22-file flow produces today, because the pack Empty becomes
exactly the group Studio would have created from a standalone file.

WHAT IS PRESERVED, AND WHY THAT IS THE WHOLE JOB
  * OBJECT NAMES. They are the contract: `src/Shared/Config/MeshColors.luau`
    and `tools/check_islet_colors.py` key colours by mesh name, and the game
    resolves parts as `Assets/<PackName>/<Prefix>_<Part>`. A renamed object
    imports grey or is simply not found. Blender makes object names unique
    per .blend, so two packs in ONE bundle that share an object name would
    silently become `X` and `X.001` - which is why the grouping below is
    partly determined by a name-collision scan, and why the script asserts
    every imported object kept its source name.
  * TRANSFORMS. Parenting to an Empty at the identity leaves each object's
    local matrix untouched, so world placement is bit-for-bit what the source
    had. This matters: `Wrack_*` is one coherent ship authored at final
    positions, and every island group is authored around its own origin.
  * MATERIALS / COLOURS. The sources carry no textures and no vertex-colour
    layers at all (checked: POSITION + NORMAL only, zero images) - every
    colour is a material `baseColorFactor`, plus `emissiveFactor` on the
    glowing ones. The glTF importer creates a fresh material datablock per
    import, so two files that happen to share a material NAME cannot repaint
    each other (the hazard `boss_wrack.glb` renamed its materials to avoid);
    the roundtrip check below proves it per object rather than trusting it.

THE GROUPING
  bundle_world.glb   IslandPack                (7 islands + 9 islets)
  bundle_bosses.glb  7 arenas + 7 boss packs + KrakenGullet + the FX pack
                     + the standalone `Maelstrom` arena group
  bundle_gear.glb    RodPack WeaponPack ArmorPack BoatPack FishPack
                     CreaturePack

  Three, not one, for two reasons and only two:
  1. SIZE. island_pack.glb alone is 31 MB. Keeping it alone keeps every
     bundle under ~40 MB and ~1500 objects, which is what Studio's importer
     is comfortable with.
  2. NAME COLLISIONS. `island_maelstrom.glb`'s nine objects are the SAME
     NINE NAMES as `island_pack.glb`'s Maelstrom group (row 1b says so: the
     pack covers the standalone file). Those two packs therefore cannot share
     a bundle - Blender would rename the second set - so `Maelstrom` rides
     with the bosses, whose arena it is. Likewise `CreaturePack` holds the
     bosses' small overworld stand-ins (`Kraken_Eyes`, `Gnashroot_Eyes`,
     `Rimefang_Body/_Eyes`, `Noctyss_Eyes`, `Pyrelisk_Eyes`), which collide
     with the boss packs' names - so gear and bosses are separate bundles.
     Both collisions exist in the Assets tree today and are harmless there
     (each lives under its own pack, and the one recursive lookup from
     Assets, `Wrack_HullCollider`, is unique); they only constrain which
     packs may share one .glb.

  The dialog settings do not constrain the grouping: all 24 rows want the
  same ones (no scaling, no mesh merging), so any split would do.

RUN
    blender -b -P assets/bundle_gen.py              # build assets/bundles/
    blender -b -P assets/bundle_gen.py -- --check   # verify, write nothing

  `--check` re-derives the bundles in memory from the sources and compares a
  content hash of the OBJECT SET (pack, name, type, vert/poly counts, local
  bbox, world matrix, material colours) against assets/bundles/MANIFEST.json.
  It hashes the object set rather than .glb bytes because a glTF export is
  not reproducible byte-for-byte; exit status 1 means the bundles are stale
  and must be rebuilt. It also re-hashes the bundle FILES against the
  manifest, which catches a bundle that was deleted or edited by hand.

THE GEOMETRY TABLE
A build also splices a generated Lua table into
`tools/studio_import_bundles.lua`, between the `-- GEOMETRY BEGIN` /
`-- GEOMETRY END` markers: per pack, per object, the bounding-box size in studs
and the bbox centre relative to the pack's anchor object, in Roblox axes. The
Studio script measures every imported MeshPart against it, which is the only
check that catches an import that arrived with the right NAMES at the wrong
SIZE (a non-1 scale in the Import dialog) or in the wrong PLACE. It is spliced
rather than written as its own file because the command bar cannot `require`
anything. `--check` also verifies the spliced block is current.
"""

import hashlib
import json
import os
import struct
import sys

import bpy
import numpy as np

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ASSETS = os.path.join(ROOT, "assets")
OUT_DIR = os.path.join(ASSETS, "bundles")
MANIFEST = os.path.join(OUT_DIR, "MANIFEST.json")

# The Studio command-bar script this generator splices the geometry table into.
# It CANNOT `require` a second file (the command bar has no module loader and no
# script instance to resolve a path from), so the table is written INTO it,
# between two marker comments, leaving every other line of the file alone.
LUA_TARGET = os.path.join(ROOT, "tools", "studio_import_bundles.lua")
LUA_BEGIN = "-- GEOMETRY BEGIN (generated by assets/bundle_gen.py - do not edit)"
LUA_END = "-- GEOMETRY END"

# (source file, pack name under ReplicatedStorage.Assets).
#
# The pack names are the ones the game looks up, verified against
# tools/studio_import.lua's ROWS ledger and, for the three rows that ledger
# has no entry for yet, against docs/import-checklist.md rows 7m and 7q and
# the `PACK_NAME` declarations in src/Client/Controllers/*BodyController.luau.
BUNDLES = {
    "bundle_world.glb": [
        ("island_pack.glb", "IslandPack"),
    ],
    "bundle_bosses.glb": [
        ("island_maelstrom.glb", "Maelstrom"),
        ("arena_brinejaw.glb", "BrinejawArena"),
        ("boss_brinejaw.glb", "BrinejawPack"),
        ("brinejaw_fx.glb", "BrinejawFxPack"),
        ("arena_gnashroot.glb", "GnashrootArena"),
        ("boss_gnashroot.glb", "GnashrootPack"),
        ("arena_rimefang.glb", "RimefangArena"),
        ("boss_rimefang.glb", "RimefangPack"),
        ("arena_wrack.glb", "WrackArena"),
        ("boss_wrack.glb", "WrackPack"),
        ("arena_noctyss.glb", "NoctyssArena"),
        ("boss_noctyss.glb", "NoctyssPack"),
        ("arena_pyrelisk.glb", "PyreliskArena"),
        ("arena_pyrelisk_heart.glb", "PyreliskHeart"),
        ("boss_pyrelisk.glb", "PyreliskPack"),
        ("arena_kraken.glb", "KrakenArena"),
        ("arena_kraken_gullet.glb", "KrakenGullet"),
        ("boss_kraken.glb", "KrakenPack"),
    ],
    "bundle_gear.glb": [
        ("rod.glb", "RodPack"),
        ("weapon.glb", "WeaponPack"),
        ("armor.glb", "ArmorPack"),
        ("boat.glb", "BoatPack"),
        ("fish.glb", "FishPack"),
        ("creatures.glb", "CreaturePack"),
    ],
}

# Matches assets/*_gen.py's own export() calls, so a bundle is written exactly
# the way the sources were: GLB, Y-up (Blender +Z -> Roblox +Y), modifiers
# applied, no UVs (nothing is textured).
EXPORT_KW = dict(
    export_format="GLB",
    use_selection=True,
    export_yup=True,
    export_apply=True,
    export_texcoords=False,
)


# ------------------------------------------------------------------ glb JSON


def glb_json(path):
    """The JSON chunk of a .glb, without Blender - used for the pre-flight
    name-collision scan, which must happen BEFORE anything is imported."""
    with open(path, "rb") as handle:
        data = handle.read()
    if data[:4] != b"glTF":
        raise SystemExit("not a .glb: %s" % path)
    offset = 12
    while offset < len(data):
        length, kind = struct.unpack_from("<II", data, offset)
        if kind == 0x4E4F534A:  # 'JSON'
            return json.loads(data[offset + 8 : offset + 8 + length])
        offset += 8 + length
    raise SystemExit("no JSON chunk in %s" % path)


def source_names(path):
    """Every node name in a source file, at any depth."""
    doc = glb_json(path)
    nodes = doc.get("nodes", [])
    names = []

    def walk(index):
        node = nodes[index]
        names.append(node.get("name"))
        for child in node.get("children", []):
            walk(child)

    scene = doc.get("scenes", [{}])[doc.get("scene", 0)]
    for root in scene.get("nodes", []):
        walk(root)
    return names


# ------------------------------------------------------------------ signature


def object_signature(pack, obj):
    """Two lines per object: the STRICT signature, which must survive the
    repack exactly, and the vertex count, which must not be required to.

    Material NAMES are deliberately excluded - the importer suffixes a
    duplicate datablock name (`M_Wrack_Hull.001`) and Studio names a MeshPart
    after the OBJECT anyway, so the name is not part of any contract. The
    material COLOURS are included, because they are.

    WHY THE VERTEX COUNT IS NOT IN THE STRICT SIGNATURE. A glTF file has no
    vertices, only indexed attribute streams, and the exporter dedups corners
    by (position, normal): a mesh re-exported after a round trip through
    Blender's custom split normals legitimately lands on a slightly different
    index count for identical geometry. The invariants that DO pin the
    geometry - triangle count, loop count, local bounding box and world matrix
    - are all in the strict line, so a real loss cannot hide behind this.
    """
    if obj.type == "MESH":
        mesh = obj.data
        verts = len(mesh.vertices)
        counts = "%d/%d" % (len(mesh.polygons), len(mesh.loops))
        box = ",".join("%.3f" % v for corner in obj.bound_box for v in corner)
    else:
        verts = 0
        counts = "-/-"
        box = "-"
    matrix = ",".join("%.3f" % v for row in obj.matrix_world for v in row)
    colours = []
    for slot in obj.material_slots:
        material = slot.material
        if material is None:
            colours.append("none")
            continue
        base, emit, strength = None, None, None
        if material.node_tree is not None:
            for node in material.node_tree.nodes:
                if node.type == "BSDF_PRINCIPLED":
                    base = tuple(node.inputs["Base Color"].default_value)
                    if "Emission Color" in node.inputs:
                        emit = tuple(node.inputs["Emission Color"].default_value)
                    if "Emission Strength" in node.inputs:
                        strength = node.inputs["Emission Strength"].default_value
                    break
        colours.append(
            "base(%s) emit(%s) s(%s)"
            % (
                "-" if base is None else ",".join("%.4f" % c for c in base),
                "-" if emit is None else ",".join("%.4f" % c for c in emit),
                "-" if strength is None else "%.4f" % strength,
            )
        )
    strict = "%s|%s|%s|%s|%s|%s|%s" % (
        pack,
        obj.name,
        obj.type,
        counts,
        box,
        matrix,
        ";".join(colours),
    )
    return strict, verts


def signature_hash(lines):
    digest = hashlib.sha256()
    for line in sorted(lines):
        digest.update(line.encode("utf-8"))
        digest.update(b"\n")
    return digest.hexdigest()


def file_hash(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


# ------------------------------------------------------------------ geometry
#
# The geometry table exists for ONE failure mode: an import that succeeds and
# is wrong. Studio's importer silently drops all glTF colour, and if the dialog
# is left on a non-1 scale (or the pivot option is flipped) every mesh still
# arrives with the right NAME - so every name check, count check and sentinel
# check in studio_import_bundles.lua passes, and the world renders at the wrong
# size. A bounding box is the cheapest thing that cannot pass when that has
# happened, so the numbers are measured here, in Blender, on the very bundle
# that is being written, and shipped to the Studio side as a table.
#
# TWO NUMBERS PER OBJECT, and the second one is the interesting one:
#   * SIZE - the axis-aligned bounding box of the exported geometry, in studs.
#     Catches any rescale; a uniform ratio across every object names it.
#   * CENTRE RELATIVE TO THE PACK'S ANCHOR - the offset from the anchor
#     object's bbox centre to this object's bbox centre. Absolute positions are
#     useless (Studio drops the import wherever it likes, and the game moves
#     every pack anyway); the RELATIVE layout is the contract - it is what
#     makes a boss's arm sit on its shoulder - and it survives any whole-pack
#     translation while still catching a per-object shift or rotation.
#
# ROBLOX AXES. The bundles are exported with export_yup=True, which is
# Blender (x, y, z) -> glTF/Roblox (x, z, -y). Sizes map (x, y, z) -> (x, z, y)
# and centres (x, y, z) -> (x, z, -y).


def world_aabb_rbx(obj, depsgraph):
    """One object's world-space AABB, in Roblox axes and studs.

    Measured on the EVALUATED mesh because the bundles are exported with
    export_apply=True: a modifier that Blender applies at export time is part
    of the geometry Studio receives, so it must be part of the box too.

    Read off the vertices rather than obj.bound_box + the matrix: the AABB of
    the transformed corners of a local AABB is a superset (and so silently too
    large) the moment an object carries a rotation, and several boss pieces do.
    """
    evaluated = obj.evaluated_get(depsgraph)
    mesh = evaluated.to_mesh()
    try:
        count = len(mesh.vertices)
        if count == 0:
            return None
        flat = np.empty(count * 3, dtype=np.float64)
        mesh.vertices.foreach_get("co", flat)
        matrix = np.array(evaluated.matrix_world, dtype=np.float64)
        world = flat.reshape((count, 3)) @ matrix[:3, :3].T + matrix[:3, 3]
    finally:
        evaluated.to_mesh_clear()
    low = world.min(axis=0)
    high = world.max(axis=0)
    size = high - low
    centre = (high + low) * 0.5
    return (
        (float(size[0]), float(size[2]), float(size[1])),
        (float(centre[0]), float(centre[2]), -float(centre[1])),
    )


def group_of(obj, wrapper):
    """The object's own top-level group inside the pack.

    island_pack.glb holds one Empty per island (`Anchorage` -> `Anchorage_Base`,
    `Anchorage_Chain`, ...); most other packs are flat. Returns the object
    itself when it hangs straight off the pack wrapper.
    """
    node = obj
    while node.parent is not None and node.parent is not wrapper:
        node = node.parent
    return node if node.parent is wrapper else obj


def pack_geometry(pack, objects, problems):
    """{object name: (size, centre-relative-to-anchor, anchor name)} for one pack.

    THE ANCHOR, in the order tried:
      1. `<Group>_Base` when the object sits in a named group that has one -
         every island and islet in IslandPack, which is the pack where a
         single shared anchor would be meaningless (16 landforms, each
         authored around its own origin, hundreds of studs apart).
      2. `<Pack>_Base` - the arenas (`WrackArena_Base`, ...).
      3. The pack's first object by name, so a boss pack with no `_Base` at
         all still gets a stable, reproducible reference point.
    """
    wrapper = None
    meshes = {}
    for obj in objects:
        if obj.type == "MESH":
            meshes[obj.name] = obj
        elif obj.type == "EMPTY" and obj.name == pack and obj.parent is None:
            wrapper = obj
    if not meshes:
        return {}
    fallback = sorted(meshes)[0]

    depsgraph = bpy.context.evaluated_depsgraph_get()
    boxes = {}
    for name, obj in meshes.items():
        box = world_aabb_rbx(obj, depsgraph)
        if box is None:
            problems.append("%s: %s has no vertices - no geometry row written" % (pack, name))
            continue
        boxes[name] = box

    anchors = {}
    for name, obj in meshes.items():
        group = group_of(obj, wrapper)
        candidate = group.name + "_Base"
        if group is not obj and candidate in boxes:
            anchors[name] = candidate
        elif pack + "_Base" in boxes:
            anchors[name] = pack + "_Base"
        else:
            anchors[name] = fallback

    rows = {}
    for name, (size, centre) in sorted(boxes.items()):
        anchor = anchors[name]
        origin = boxes.get(anchor, (None, (0.0, 0.0, 0.0)))[1]
        rows[name] = (
            size,
            (centre[0] - origin[0], centre[1] - origin[1], centre[2] - origin[2]),
            anchor,
        )
    return rows


def lua_geometry_block(geometry):
    """The spliced Lua chunk: one line per object, one sub-table per pack."""
    lines = [
        LUA_BEGIN,
        "--[[",
        "\tPer pack, per object: the bounding box Studio should end up with, in",
        "\tROBLOX axes and studs, measured in Blender on the very bundle in",
        "\tassets/bundles/. Each row is",
        "",
        "\t    { sizeX, sizeY, sizeZ, centreX, centreY, centreZ, anchorObjectName }",
        "",
        "\twhere the centre is RELATIVE to the anchor object's own bbox centre, so",
        "\tthe check is blind to where Studio dropped the import and to where the",
        "\tgame moves the pack afterwards, and sees only the layout inside it.",
        "",
        "\tRegenerate with `blender --background --python assets/bundle_gen.py`;",
        "\tit rewrites everything between the two markers and nothing else.",
        "]]",
        "local GEOMETRY = {",
    ]
    total = 0
    for pack in sorted(geometry):
        rows = geometry[pack]
        lines.append("\t%s = {" % pack)
        for name in sorted(rows):
            size, centre, anchor = rows[name]
            total += 1
            lines.append(
                '\t\t["%s"] = { %.3f, %.3f, %.3f, %.3f, %.3f, %.3f, "%s" },'
                % (name, size[0], size[1], size[2], centre[0], centre[1], centre[2], anchor)
            )
        lines.append("\t},")
    lines.append("}")
    lines.append(LUA_END)
    return "\n".join(lines), total


def splice_geometry(geometry):
    """Replace the marked block in tools/studio_import_bundles.lua in place.

    Asserts both markers exist EXACTLY once before writing anything: a splice
    that silently appended (or matched a marker quoted in a comment) would
    leave a file that still compiles and verifies nothing.
    """
    with open(LUA_TARGET, encoding="utf-8") as handle:
        text = handle.read()
    begins = text.count(LUA_BEGIN)
    ends = text.count(LUA_END)
    if begins != 1 or ends != 1:
        raise SystemExit(
            "splice ABORTED: %s must hold each marker exactly once "
            "(found BEGIN x%d, END x%d).\n  %s\n  %s" % (LUA_TARGET, begins, ends, LUA_BEGIN, LUA_END)
        )
    start = text.index(LUA_BEGIN)
    stop = text.index(LUA_END, start) + len(LUA_END)
    if stop <= start:
        raise SystemExit("splice ABORTED: END marker precedes BEGIN in %s" % LUA_TARGET)
    block, total = lua_geometry_block(geometry)
    with open(LUA_TARGET, "w", encoding="utf-8") as handle:
        handle.write(text[:start] + block + text[stop:])
    return total


# ------------------------------------------------------------------ blender


def fresh_scene():
    bpy.ops.wm.read_factory_settings(use_empty=True)


def import_pack(path, pack, problems):
    """Import one source file and wrap its roots under an Empty named `pack`.

    Returns the list of objects that file contributed. Every assertion here is
    about a SILENT failure: a renamed object, a missing object, or a wrapper
    that did not get the pack's exact name, each of which produces a game that
    runs and quietly draws a stand-in.
    """
    before = set(bpy.data.objects)
    bpy.ops.import_scene.gltf(filepath=path)
    fresh = [obj for obj in bpy.data.objects if obj not in before]

    got = sorted(obj.name for obj in fresh)
    want = sorted(n for n in source_names(path) if n is not None)
    if got != want:
        missing = sorted(set(want) - set(got))
        extra = sorted(set(got) - set(want))
        if missing:
            problems.append("%s: names LOST on import: %s" % (pack, ", ".join(missing)))
        if extra:
            problems.append("%s: names INVENTED on import (a rename): %s" % (pack, ", ".join(extra)))

    wrapper = bpy.data.objects.new(pack, None)
    bpy.context.scene.collection.objects.link(wrapper)
    if wrapper.name != pack:
        problems.append(
            "%s: wrapper Empty came out as '%s' - the pack name is already taken in this bundle" % (pack, wrapper.name)
        )
    for obj in fresh:
        if obj.parent is None:
            # Empty is at the identity, so the child's local matrix IS its
            # world matrix and nothing moves.
            obj.parent = wrapper
    return fresh + [wrapper]


def build_bundle(bundle, members, export, problems):
    """Import every member of one bundle into a fresh scene. Returns its
    signature lines. Exports only when `export` is true."""
    fresh_scene()
    lines, verts = [], {}
    per_pack = {}
    geometry = {}
    for filename, pack in members:
        path = os.path.join(ASSETS, filename)
        if not os.path.exists(path):
            problems.append("%s: source file missing: %s" % (pack, path))
            continue
        objects = import_pack(path, pack, problems)
        per_pack[pack] = len([o for o in objects if o.type == "MESH"])
        for obj in objects:
            strict, nverts = object_signature(pack, obj)
            lines.append(strict)
            verts[(pack, obj.name)] = nverts
        # Measured on the objects as they will be exported, before the next
        # fresh_scene() throws them away.
        geometry[pack] = pack_geometry(pack, objects, problems)

    out_path = os.path.join(OUT_DIR, bundle)
    if export:
        os.makedirs(OUT_DIR, exist_ok=True)
        bpy.ops.object.select_all(action="SELECT")
        bpy.ops.export_scene.gltf(filepath=out_path, **EXPORT_KW)
    return lines, verts, per_pack, geometry


def roundtrip(bundle, expected_lines, expected_verts, problems):
    """Re-import the exported bundle into a fresh scene and assert the object
    set came back identical.

    The pack a re-imported object belongs to is read from the tree (walk up to
    the Empty that is a direct child of the scene root), which is exactly how
    `studio_import_bundles.lua` will split the import in Studio - so this
    verifies the SPLIT, not just the geometry.
    """
    path = os.path.join(OUT_DIR, bundle)
    fresh_scene()
    bpy.ops.import_scene.gltf(filepath=path)

    lines, verts = [], {}
    for obj in bpy.data.objects:
        top = obj
        while top.parent is not None:
            top = top.parent
        # A wrapper is its own pack; everything else belongs to the wrapper it
        # hangs under, which is exactly how the Studio script splits it.
        pack = obj.name if top is obj else top.name
        strict, nverts = object_signature(pack, obj)
        lines.append(strict)
        verts[(pack, obj.name)] = nverts

    # Advisory, never fatal - see object_signature's docstring.
    drift = [
        (key, expected_verts[key], verts[key])
        for key in sorted(set(expected_verts) & set(verts))
        if expected_verts[key] != verts[key]
    ]
    if drift:
        worst = max(abs(b - a) for _, a, b in drift)
        print(
            "     note: %d of %d objects came back with a different glTF vertex-index\n"
            "           count (worst delta %d) - triangle count, loop count, bounding\n"
            "           box, transform and colours are all unchanged, so this is the\n"
            "           exporter welding corners differently, not lost geometry."
            % (len(drift), len(verts), worst)
        )

    want, got = set(expected_lines), set(lines)
    if want == got:
        return True

    # Report at the level a human can act on: which (pack, name) pairs differ,
    # and for pairs present on both sides, which field drifted.
    def key(line):
        parts = line.split("|")
        return (parts[0], parts[1])

    want_map = {key(l): l for l in want}
    got_map = {key(l): l for l in got}
    for missing in sorted(set(want_map) - set(got_map)):
        problems.append("%s: roundtrip LOST %s/%s" % (bundle, missing[0], missing[1]))
    for extra in sorted(set(got_map) - set(want_map)):
        problems.append("%s: roundtrip GAINED %s/%s" % (bundle, extra[0], extra[1]))
    fields = ["pack", "name", "type", "polys/loops", "bbox", "matrix", "colours"]
    for shared in sorted(set(want_map) & set(got_map)):
        a, b = want_map[shared].split("|"), got_map[shared].split("|")
        for index, field in enumerate(fields):
            if a[index] != b[index]:
                problems.append(
                    "%s: %s/%s %s changed: %s -> %s" % (bundle, shared[0], shared[1], field, a[index], b[index])
                )
    return False


# ------------------------------------------------------------------ collisions


def collision_scan():
    """Which object names are owned by more than one pack.

    Two findings, not one:
      * WITHIN a bundle it is fatal - Blender would rename the second one, and
        the renamed object imports grey (no MeshColors row) or is never found.
      * ACROSS the whole Assets tree it is only worth knowing about, because
        each pack is its own folder. The ONE place it could bite is a
        RECURSIVE `FindFirstChild` starting at `Assets`, and there is exactly
        one in the codebase (`Wrack_HullCollider`, CreatureService), whose
        name is unique.
    """
    owner = {}
    for bundle, members in BUNDLES.items():
        for filename, pack in members:
            path = os.path.join(ASSETS, filename)
            if not os.path.exists(path):
                continue
            for name in source_names(path):
                if name is None:
                    continue
                owner.setdefault(name, []).append((bundle, pack))

    global_dups, fatal = [], []
    for name, owners in sorted(owner.items()):
        packs = sorted({pack for _, pack in owners})
        if len(packs) < 2:
            continue
        global_dups.append((name, packs))
        bundles = {}
        for bundle, pack in owners:
            bundles.setdefault(bundle, set()).add(pack)
        for bundle, packs_here in bundles.items():
            if len(packs_here) > 1:
                fatal.append((bundle, name, sorted(packs_here)))
    return global_dups, fatal


# ------------------------------------------------------------------ main


def main():
    argv = sys.argv[sys.argv.index("--") + 1 :] if "--" in sys.argv else []
    check_only = "--check" in argv

    print("")
    print("=" * 70)
    print("bundle_gen.py - %s" % ("CHECK (writes nothing)" if check_only else "BUILD"))
    print("  sources : %s" % ASSETS)
    print("  bundles : %s" % OUT_DIR)
    print("=" * 70)

    problems = []
    global_dups, fatal = collision_scan()

    print("")
    print("NAME COLLISIONS across packs (%d):" % len(global_dups))
    for name, packs in global_dups:
        print("  %-22s %s" % (name, ", ".join(packs)))
    if not global_dups:
        print("  none")
    print(
        "  -> harmless in the Assets tree (one folder each; the only recursive\n"
        "     lookup from Assets is Wrack_HullCollider, which is unique), but\n"
        "     fatal INSIDE one bundle, which is what the next line checks."
    )
    if fatal:
        for bundle, name, packs in fatal:
            problems.append("FATAL: %s holds '%s' twice (%s) - Blender would rename one" % (bundle, name, ", ".join(packs)))
        print("  SAME-BUNDLE COLLISIONS: %d - see problems below" % len(fatal))
        for line in problems:
            print("  " + line)
        return 1
    print("  same-bundle collisions: none")

    manifest = {}
    if check_only and os.path.exists(MANIFEST):
        with open(MANIFEST) as handle:
            manifest = json.load(handle)
    elif check_only:
        print("")
        print("STALE: %s does not exist - the bundles have never been built." % MANIFEST)
        return 1

    out = {}
    all_geometry = {}
    stale = False
    for bundle, members in BUNDLES.items():
        print("")
        print("---- %s  (%d packs)" % (bundle, len(members)))
        lines, verts, per_pack, geometry = build_bundle(bundle, members, export=not check_only, problems=problems)
        all_geometry.update(geometry)
        # The hash covers the vertex counts too: they are deterministic on THIS
        # side (both --check and the build read them from the same source
        # import), so including them makes the staleness check sharper. Only the
        # roundtrip comparison has to tolerate them drifting.
        digest = signature_hash("%s|v%d" % (line, verts.get((line.split("|")[0], line.split("|")[1]), 0)) for line in lines)
        path = os.path.join(OUT_DIR, bundle)

        for filename, pack in members:
            print("     %-28s -> %-16s %4d meshes" % (filename, pack, per_pack.get(pack, 0)))
        print("     objects: %d (incl. %d pack wrappers)" % (len(lines), len(members)))
        print("     object-set hash: %s" % digest[:16])

        if check_only:
            record = manifest.get("bundles", {}).get(bundle)
            if record is None:
                print("     STALE: not in the manifest")
                stale = True
                continue
            if record.get("object_hash") != digest:
                print("     STALE: sources have changed since the bundle was built")
                print("       manifest %s" % record.get("object_hash", "?")[:16])
                print("       sources  %s" % digest[:16])
                stale = True
            elif not os.path.exists(path):
                print("     STALE: %s is missing" % path)
                stale = True
            elif file_hash(path) != record.get("file_hash"):
                print("     STALE: %s was modified or re-exported outside this script" % bundle)
                stale = True
            else:
                print("     up to date")
            continue

        size = os.path.getsize(path)
        print("     exported: %.1f MB" % (size / 1e6))
        if roundtrip(bundle, lines, verts, problems):
            print("     roundtrip: OK - every object came back with its name, counts, transform and colours")
        else:
            print("     roundtrip: FAILED - see problems below")
        out[bundle] = {
            "packs": [pack for _, pack in members],
            "sources": [filename for filename, _ in members],
            "objects": len(lines),
            "bytes": size,
            "object_hash": digest,
            "file_hash": file_hash(path),
        }

    print("")
    print("=" * 70)
    if problems:
        print("PROBLEMS (%d):" % len(problems))
        for line in problems:
            print("  " + line)
        return 1

    if check_only:
        # The spliced geometry table is as stale-able as the bundles: a mesh
        # that changed size changes the numbers Studio is checked against, and
        # a table left behind would fail every re-import with numbers from the
        # previous build. Same exit status as a stale bundle.
        want, total = lua_geometry_block(all_geometry)
        if not os.path.exists(LUA_TARGET):
            print("")
            print("STALE: %s does not exist - cannot check the geometry table." % LUA_TARGET)
            stale = True
        else:
            with open(LUA_TARGET, encoding="utf-8") as handle:
                text = handle.read()
            if text.count(LUA_BEGIN) != 1 or text.count(LUA_END) != 1:
                print("")
                print("STALE: the GEOMETRY markers are missing from %s" % LUA_TARGET)
                stale = True
            else:
                start = text.index(LUA_BEGIN)
                stop = text.index(LUA_END, start) + len(LUA_END)
                if text[start:stop] == want:
                    print("")
                    print("geometry table: up to date (%d objects) in %s" % (total, os.path.basename(LUA_TARGET)))
                else:
                    print("")
                    print("STALE: the GEOMETRY block in %s was written for" % os.path.basename(LUA_TARGET))
                    print("       different meshes - re-run without --check.")
                    stale = True
        if stale:
            print("CHECK FAILED: re-run `blender -b -P assets/bundle_gen.py`")
            return 1
        print("CHECK OK: assets/bundles/*.glb match the sources.")
        return 0

    with open(MANIFEST, "w") as handle:
        json.dump(
            {
                "note": "written by assets/bundle_gen.py - object-set hashes, for --check",
                "bundles": out,
            },
            handle,
            indent=2,
            sort_keys=True,
        )
        handle.write("\n")
    objects = splice_geometry(all_geometry)
    print(
        "SPLICED the geometry table (%d packs, %d objects) into %s"
        % (len(all_geometry), objects, os.path.relpath(LUA_TARGET, ROOT))
    )

    total = sum(record["bytes"] for record in out.values())
    print("BUILT %d bundles, %.1f MB total, %d objects." % (len(out), total / 1e6, sum(r["objects"] for r in out.values())))
    print("Next: Studio import per docs/import-quick.md, then tools/studio_import_bundles.lua.")
    print("=" * 70)
    return 0


if __name__ == "__main__":
    sys.exit(main())
