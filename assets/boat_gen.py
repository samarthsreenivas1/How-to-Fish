# boat_gen.py
# Generates the six boat-tier hulls as low-poly meshes and exports them
# together as one glTF pack (.glb) - the BoatPack, the same "one import" idea
# as the WeaponPack / RodPack / FishPack / CreaturePack. Run headless:
#
#   blender --background --python assets/boat_gen.py -- assets/boat.glb
#   blender --background --python assets/boat_gen.py -- assets/boat.glb preview
#
# The second form also writes assets/boat_preview.png (the fleet lined up).
#
# One pack, six boats: each variant is exported as <Variant>_Hull / _Deck /
# _Bow / _Mast / _Sail / _Rail / _Trim / _Lantern / _Figurehead / _Shelf /
# _Helm (only the parts it uses), all overlapping at the origin. BoatModel
# (Session 3) clones one variant's parts out by name, renames them to the
# generic Boat_* set, and welds them massless/non-colliding to its own
# invisible collider - these meshes are purely cosmetic.
#
# Authoring contract (locked with Session 3's BoatModel):
#   - 1 Blender unit = 1 Roblox stud. Exported Y-up (Blender +z -> Roblox +Y).
#     Studio's importer yaws the model 180 about Y (Blender -y -> Roblox -Z,
#     the rod_gen.py gotcha), and BoatModel wants the bow on Roblox -Z, so
#     THE BOW POINTS ALONG BLENDER -y. Verify with one Studio import before
#     trusting a new variant.
#   - Local origin is the WATERLINE amidships: z = 0 is the waterline, the
#     keel sits at -draft, the deck top at +deck (per-tier numbers below,
#     matching Boats.luau / BoatModel's collider exactly).
#   - <Variant>_Helm is a small marker part: its position is where BoatModel
#     places the VehicleSeat (it hides the marker; identity rotation already
#     faces the bow after import).
#   - <Variant>_Shelf is a low stern box with a clear top face - BoatModel
#     puts the HeartMount1..6 Attachments in a row on its top for the boss
#     trophy renderer.
#   - Flat shading everywhere, matching the other packs.
#
# Colours here are only for the preview; in game BoatModel recolours by part
# name (Hull/Bow = hull, Deck = deck, Sail = sail, Trim/Rail = trim,
# Lantern = glow/Neon). The preview colours below mirror that scheme.

import math
import sys

import bmesh
import bpy
from mathutils import Matrix, Vector

TAU = math.tau

# Per-tier dimensions, locked with Boats.luau / BoatModel's collider:
# length (studs, along the bow axis), beam (across), deck top above the
# waterline, draft below it.
VARIANTS = [
    {
        "name": "CoveSkiff",
        "length": 14.0,
        "beam": 5.0,
        "deck": 1.2,
        "draft": 0.9,
        "mast": False,
        "trim": None,
        "lanterns": [],
        "figurehead": False,
        "jib": False,
        "keel_glow": False,
        "colors": {
            "Hull": (0.55, 0.42, 0.27),  # driftwood planks
            "Deck": (0.66, 0.53, 0.36),
            "Bow": (0.46, 0.34, 0.21),
            "Rail": (0.46, 0.34, 0.21),
            "Shelf": (0.4, 0.31, 0.22),
            "Helm": (0.35, 0.28, 0.2),
        },
    },
    {
        "name": "IronbogHull",
        "length": 16.0,
        "beam": 5.5,
        "deck": 1.4,
        "draft": 1.0,
        "mast": True,
        "trim": "belt",
        "lanterns": [],
        "figurehead": False,
        "jib": False,
        "keel_glow": False,
        "colors": {
            "Hull": (0.42, 0.32, 0.21),  # bogwood
            "Deck": (0.5, 0.4, 0.28),
            "Bow": (0.35, 0.33, 0.29),  # bog-iron stem
            "Rail": (0.3, 0.24, 0.17),
            "Trim": (0.35, 0.33, 0.29),  # bog-iron belt
            "Mast": (0.38, 0.29, 0.19),
            "Sail": (0.72, 0.68, 0.55),  # stained canvas
            "Shelf": (0.32, 0.26, 0.19),
            "Helm": (0.3, 0.25, 0.19),
        },
    },
    {
        "name": "IcebreakerProw",
        "length": 18.0,
        "beam": 6.0,
        "deck": 1.6,
        "draft": 1.1,
        "mast": True,
        "trim": "belt",
        "lanterns": [],
        "figurehead": False,
        "jib": False,
        "keel_glow": False,
        "colors": {
            "Hull": (0.5, 0.44, 0.36),  # pale timber
            "Deck": (0.6, 0.55, 0.46),
            "Bow": (0.62, 0.72, 0.8),  # ice-steel prow
            "Rail": (0.4, 0.36, 0.3),
            "Trim": (0.62, 0.72, 0.8),
            "Mast": (0.45, 0.39, 0.31),
            "Sail": (0.85, 0.88, 0.9),
            "Shelf": (0.38, 0.33, 0.27),
            "Helm": (0.35, 0.31, 0.26),
        },
    },
    {
        "name": "AshguardPlating",
        "length": 20.0,
        "beam": 6.5,
        "deck": 1.8,
        "draft": 1.2,
        "mast": True,
        "trim": "plates",
        "lanterns": [],
        "figurehead": False,
        "jib": False,
        "keel_glow": False,
        "colors": {
            "Hull": (0.3, 0.24, 0.2),  # charred timber
            "Deck": (0.36, 0.3, 0.25),
            "Bow": (0.19, 0.17, 0.24),  # obsidian ram
            "Rail": (0.24, 0.2, 0.18),
            "Trim": (0.19, 0.17, 0.24),  # obsidian plates
            "Mast": (0.28, 0.23, 0.19),
            "Sail": (0.55, 0.33, 0.2),  # ember-dyed canvas
            "Shelf": (0.26, 0.21, 0.18),
            "Helm": (0.24, 0.2, 0.17),
        },
    },
    {
        "name": "AbyssalLanterns",
        "length": 22.0,
        "beam": 7.0,
        "deck": 2.0,
        "draft": 1.3,
        "mast": True,
        "trim": None,
        "lanterns": [(0.35, 1), (0.35, -1), (-0.2, 1), (-0.2, -1)],
        "figurehead": False,
        "jib": False,
        "keel_glow": False,
        "colors": {
            "Hull": (0.16, 0.17, 0.22),  # abyss-dark
            "Deck": (0.22, 0.23, 0.28),
            "Bow": (0.2, 0.21, 0.26),
            "Rail": (0.14, 0.15, 0.19),
            "Mast": (0.19, 0.2, 0.24),
            "Sail": (0.3, 0.33, 0.4),  # dark canvas
            "Lantern": (0.45, 0.9, 0.85),  # the glands, glowing
            "Shelf": (0.18, 0.19, 0.23),
            "Helm": (0.17, 0.18, 0.22),
        },
    },
    {
        "name": "StormbreakerKeel",
        "length": 24.0,
        "beam": 8.0,
        "deck": 2.2,
        "draft": 1.4,
        "mast": True,
        "trim": "belt",
        "lanterns": [(0.38, 1), (0.38, -1)],
        "figurehead": True,
        "jib": True,
        "keel_glow": True,
        "colors": {
            "Hull": (0.23, 0.3, 0.42),  # storm-blue
            "Deck": (0.4, 0.36, 0.3),
            "Bow": (0.72, 0.6, 0.32),  # brass ram
            "Rail": (0.2, 0.25, 0.34),
            "Trim": (0.72, 0.6, 0.32),  # brass belt
            "Mast": (0.35, 0.3, 0.24),
            "Sail": (0.88, 0.9, 0.93),
            "Lantern": (0.55, 0.8, 1.0),  # storm glow (and the keel line)
            "Figurehead": (0.72, 0.6, 0.32),
            "Shelf": (0.24, 0.27, 0.33),
            "Helm": (0.22, 0.25, 0.31),
        },
    },
]

GLOW_SUFFIXES = {"Lantern"}  # emissive in the preview only (Neon in game)


# ---------------------------------------------------------------- scene + material helpers


def clear_scene():
    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.object.delete()
    for block in (bpy.data.meshes, bpy.data.materials, bpy.data.objects):
        for item in list(block):
            block.remove(item)


COLORS = {}  # filled per variant while building: "<Variant>_<Suffix>" -> rgb


def make_material(name):
    mat = bpy.data.materials.new(name)
    mat.use_nodes = True
    bsdf = mat.node_tree.nodes.get("Principled BSDF")
    r, g, b = COLORS[name]
    bsdf.inputs["Base Color"].default_value = (r, g, b, 1)
    bsdf.inputs["Roughness"].default_value = 1.0
    if name.rsplit("_", 1)[-1] in GLOW_SUFFIXES:
        bsdf.inputs["Emission Color"].default_value = (r, g, b, 1)
        bsdf.inputs["Emission Strength"].default_value = 1.6
    mat.diffuse_color = (r, g, b, 1)
    return mat


def finish(name, bm):
    """Turn a bmesh into a flat-shaded object, or None if it's empty."""
    if len(bm.faces) == 0:
        bm.free()
        return None
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces[:])
    mesh = bpy.data.meshes.new(name)
    bm.to_mesh(mesh)
    bm.free()
    obj = bpy.data.objects.new(name, mesh)
    obj.data.materials.append(make_material(name))
    for poly in mesh.polygons:
        poly.use_smooth = False
    bpy.context.collection.objects.link(obj)
    return obj


# ---------------------------------------------------------------- geometry primitives


def box(bm, center, size, rot=None):
    res = bmesh.ops.create_cube(bm, size=1.0)
    scale = Matrix.Diagonal(Vector((size[0], size[1], size[2], 1.0)))
    m = Matrix.Translation(Vector(center)) @ (rot or Matrix.Identity(4)) @ scale
    bmesh.ops.transform(bm, matrix=m, verts=res["verts"])


def ellipsoid(bm, center, radii, subdiv=1):
    res = bmesh.ops.create_icosphere(bm, subdivisions=subdiv, radius=1.0)
    scale = Matrix.Diagonal(Vector((radii[0], radii[1], radii[2], 1.0)))
    bmesh.ops.transform(bm, matrix=Matrix.Translation(Vector(center)) @ scale, verts=res["verts"])


def limb(bm, p0, p1, r0, r1, sides=6):
    """A tapered, capped tube from p0 to p1 (radius r0 -> r1)."""
    p0, p1 = Vector(p0), Vector(p1)
    axis = p1 - p0
    length = axis.length
    if length < 1e-6:
        return
    d = axis / length
    up = Vector((0, 0, 1)) if abs(d.z) < 0.9 else Vector((1, 0, 0))
    u = d.cross(up).normalized()
    v = d.cross(u).normalized()

    def rng(p, r):
        return [bm.verts.new(p + (u * math.cos(a) + v * math.sin(a)) * r) for a in ((i / sides) * TAU for i in range(sides))]

    a = rng(p0, r0)
    b = rng(p1, r1)
    for i in range(sides):
        bm.faces.new((a[i], a[(i + 1) % sides], b[(i + 1) % sides], b[i]))
    bm.faces.new(list(reversed(a)))
    bm.faces.new(b)


def cone(bm, base, tip, r, sides=5):
    base, tip = Vector(base), Vector(tip)
    d = (tip - base).normalized()
    up = Vector((0, 0, 1)) if abs(d.z) < 0.9 else Vector((1, 0, 0))
    u = d.cross(up).normalized()
    v = d.cross(u).normalized()
    rim = [bm.verts.new(base + (u * math.cos(a) + v * math.sin(a)) * r) for a in ((i / sides) * TAU for i in range(sides))]
    apex = bm.verts.new(tip)
    for i in range(sides):
        bm.faces.new((rim[i], rim[(i + 1) % sides], apex))
    bm.faces.new(list(reversed(rim)))


def panel(bm, pts_yz, x0, x1):
    """Extrude a flat (y, z) silhouette into a thin slab spanning x0..x1 (a
    sail, a stem blade). The two broad faces are the caps."""
    front = [bm.verts.new(Vector((x0, y, z))) for y, z in pts_yz]
    back = [bm.verts.new(Vector((x1, y, z))) for y, z in pts_yz]
    n = len(pts_yz)
    for i in range(n):
        j = (i + 1) % n
        bm.faces.new((front[i], front[j], back[j], back[i]))
    bm.faces.new(list(reversed(front)))
    bm.faces.new(back)


# ---------------------------------------------------------------- the hull loft

# Station spacing along the length (x length fraction, bow -0.5 first) and the
# hull's width / keel / sheer profiles at each station. One shared shape for
# every tier - the dims scale it.
STATIONS = [-0.5, -0.34, -0.16, 0.04, 0.22, 0.38, 0.5]
WIDTH_AT = [0.1, 0.62, 0.88, 1.0, 0.97, 0.88, 0.74]
KEEL_AT = [0.25, 0.7, 0.95, 1.0, 0.95, 0.8, 0.5]  # x draft, downward
SHEER_AT = [0.5, 0.18, 0.04, 0.0, 0.02, 0.1, 0.2]  # extra gunwale rise
U_POINTS = 7  # verts per cross-section ring


def hull_loft(bm, length, beam, deck, draft):
    rings = []
    for s, wf, kf, sh in zip(STATIONS, WIDTH_AT, KEEL_AT, SHEER_AT):
        y = s * length
        w = wf * beam / 2
        gz = deck + sh
        kz = -kf * draft
        ring = []
        for k in range(U_POINTS):
            theta = (k / (U_POINTS - 1)) * math.pi
            x = w * math.cos(theta)
            z = gz - (gz - kz) * math.sin(theta)
            ring.append(bm.verts.new(Vector((x, y, z))))
        rings.append(ring)
    # Shell quads between stations.
    for a, b in zip(rings, rings[1:]):
        for i in range(U_POINTS - 1):
            bm.faces.new((a[i], a[i + 1], b[i + 1], b[i]))
        # Close the top between the two gunwale lines (the hull's own deck
        # plane, under the planked _Deck part).
        bm.faces.new((a[0], b[0], b[-1], a[-1]))
    # Cap the bow and stern cross-sections.
    bm.faces.new(list(reversed(rings[0])))
    bm.faces.new(rings[-1])


# ---------------------------------------------------------------- one boat


def build_boat(cfg):
    name = cfg["name"]
    L, beam, deck, draft = cfg["length"], cfg["beam"], cfg["deck"], cfg["draft"]
    for suffix, rgb in cfg["colors"].items():
        COLORS[f"{name}_{suffix}"] = rgb

    parts = {}

    # Hull.
    hull = bmesh.new()
    hull_loft(hull, L, beam, deck, draft)
    parts["Hull"] = hull

    # Deck planking, sitting just under the gunwale line.
    deck_bm = bmesh.new()
    box(deck_bm, (0, 0.06 * L, deck - 0.16), (beam * 0.68, L * 0.78, 0.14))
    parts["Deck"] = deck_bm

    # Bow stem: a raked blade at the bow (Blender -y). The Icebreaker gets a
    # wider, deeper wedge - its whole point.
    bow = bmesh.new()
    stem_half = 0.14 if name == "IcebreakerProw" else 0.07
    stem = [
        (-0.5 * L - 0.4, deck + 0.75),
        (-0.5 * L + 0.15, deck + 0.35),
        (-0.5 * L + 0.75, -draft * 0.75),
        (-0.5 * L - 0.05, -draft * 0.35),
    ]
    panel(bow, stem, -stem_half, stem_half)
    parts["Bow"] = bow

    # Rails along both gunwales plus a stern rail.
    rail = bmesh.new()
    for side in (-1, 1):
        box(rail, (side * (beam / 2 * 0.9), 0.04 * L, deck + 0.24), (0.14, L * 0.6, 0.3))
    box(rail, (0, 0.47 * L, deck + 0.28), (beam * 0.68, 0.14, 0.34))
    parts["Rail"] = rail

    # Trim: a bog-iron/brass belt at the waterline, or the Ashguard's plates.
    if cfg["trim"]:
        trim = bmesh.new()
        if cfg["trim"] == "belt":
            for side in (-1, 1):
                box(trim, (side * (beam / 2 * 0.96), 0, deck * 0.3), (0.12, L * 0.56, 0.4))
        else:  # plates
            for side in (-1, 1):
                for row_z in (deck * 0.25, deck * 0.72):
                    box(trim, (side * (beam / 2 * 0.96), 0, row_z), (0.12, L * 0.52, 0.5))
        parts["Trim"] = trim

    # Mast + sail (every tier past the skiff).
    if cfg["mast"]:
        mast_y = -0.06 * L
        mast_h = L * 0.52
        mast = bmesh.new()
        limb(mast, (0, mast_y, deck - 0.1), (0, mast_y, deck + mast_h), 0.15, 0.09, 6)
        limb(mast, (0, mast_y + 0.05, deck + mast_h * 0.28), (0, mast_y + L * 0.3, deck + mast_h * 0.24), 0.07, 0.05, 5)  # boom
        parts["Mast"] = mast

        sail = bmesh.new()
        tri = [
            (mast_y + 0.18, deck + mast_h * 0.92),
            (mast_y + L * 0.29, deck + mast_h * 0.28),
            (mast_y + 0.18, deck + mast_h * 0.28),
        ]
        panel(sail, tri, -0.04, 0.04)
        if cfg["jib"]:
            jib = [
                (mast_y - 0.2, deck + mast_h * 0.86),
                (mast_y - 0.2, deck + mast_h * 0.28),
                (-0.47 * L, deck + 0.45),
            ]
            panel(sail, jib, -0.04, 0.04)
        parts["Sail"] = sail

    # Lantern posts (posts ride _Rail's colour; the glands glow).
    if cfg["lanterns"]:
        lantern = bmesh.new()
        for yf, side in cfg["lanterns"]:
            px = side * (beam / 2 * 0.78)
            py = yf * L
            limb(parts["Rail"], (px, py, deck), (px, py, deck + 1.5), 0.07, 0.055, 5)
            ellipsoid(lantern, (px, py, deck + 1.68), (0.24, 0.24, 0.3), subdiv=1)
        parts["Lantern"] = lantern

    # Stormbreaker extras: brass figurehead at the bow, glowing keel line.
    if cfg["figurehead"]:
        fig = bmesh.new()
        ellipsoid(fig, (0, -0.5 * L - 0.15, deck + 0.95), (0.3, 0.5, 0.32), subdiv=1)
        cone(fig, (0, -0.5 * L - 0.5, deck + 0.95), (0, -0.5 * L - 1.05, deck + 0.8), 0.16, sides=5)
        parts["Figurehead"] = fig
    if cfg["keel_glow"]:
        if "Lantern" not in parts:
            parts["Lantern"] = bmesh.new()
        box(parts["Lantern"], (0, 0, -draft - 0.02), (0.22, L * 0.55, 0.14))

    # The trophy shelf: a low stern box, top face clear, wide enough for the
    # six HeartMount attachments BoatModel puts on it.
    shelf = bmesh.new()
    shelf_w = min(max(6.0, beam * 0.75), beam - 0.6)
    box(shelf, (0, 0.42 * L, deck + 0.3), (shelf_w, 1.3, 0.6))
    parts["Shelf"] = shelf

    # The helm marker: BoatModel replaces it with the VehicleSeat.
    helm = bmesh.new()
    box(helm, (0, 0.3 * L, deck + 0.42), (0.45, 0.45, 0.84))
    parts["Helm"] = helm

    return [finish(f"{name}_{suffix}", bm) for suffix, bm in parts.items()]


# ---------------------------------------------------------------- preview


def render_preview(groups, out_png):
    scene = bpy.context.scene
    try:
        scene.render.engine = "BLENDER_EEVEE_NEXT"
    except TypeError:
        scene.render.engine = "BLENDER_EEVEE"
    spacing = 30.0
    row_width = spacing * max(len(groups) - 1, 0)
    scene.render.resolution_x = 4200
    scene.render.resolution_y = 1000
    scene.render.filepath = out_png

    world = bpy.data.worlds.new("W")
    world.use_nodes = True
    world.node_tree.nodes["Background"].inputs[0].default_value = (0.32, 0.4, 0.48, 1)
    scene.world = world
    scene.view_settings.view_transform = "Standard"

    sun = bpy.data.objects.new("Sun", bpy.data.lights.new("Sun", "SUN"))
    sun.data.energy = 2.8
    sun.rotation_euler = (math.radians(52), math.radians(12), math.radians(35))
    bpy.context.collection.objects.link(sun)

    for i, objs in enumerate(groups):
        for obj in objs:
            if obj:
                obj.location.x += (i - (len(groups) - 1) / 2) * spacing

    cam = bpy.data.objects.new("Cam", bpy.data.cameras.new("Cam"))
    bpy.context.collection.objects.link(cam)
    scene.camera = cam
    # A 3/4 view from off the port bow, far enough back that the whole fleet
    # (row_width wide plus the end boats' own lengths) fits the frame.
    cam.location = Vector((-row_width * 0.42, -(row_width * 1.5 + 60.0), row_width * 0.22))
    target = Vector((0.0, 0.0, 0.5))
    cam.rotation_euler = (target - cam.location).to_track_quat("-Z", "Y").to_euler()
    cam.data.lens = 50

    bpy.ops.render.render(write_still=True)
    print("[boat_gen] preview ->", out_png)


# ---------------------------------------------------------------- export


def main():
    argv = sys.argv[sys.argv.index("--") + 1 :]
    out_path = argv[0]
    want_preview = len(argv) > 1 and argv[1] == "preview"

    clear_scene()
    groups = [build_boat(cfg) for cfg in VARIANTS]

    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.export_scene.gltf(
        filepath=out_path,
        export_format="GLB",
        use_selection=True,
        export_yup=True,
        export_materials="EXPORT",
        export_apply=True,
        export_normals=True,
        export_texcoords=False,
    )

    total = sum(len(o.data.polygons) for objs in groups for o in objs if o)
    print(f"[boat_gen] exported {out_path}")
    for cfg in VARIANTS:
        print(
            f"[boat_gen]   {cfg['name']}: {cfg['length']}x{cfg['beam']}, "
            f"deck +{cfg['deck']}, draft -{cfg['draft']} (Boats.luau must match)"
        )
    print(f"[boat_gen] boats: {', '.join(c['name'] for c in VARIANTS)}; polys: {total}")

    if want_preview:
        import os

        render_preview(groups, os.path.abspath("assets/boat_preview.png"))


main()
