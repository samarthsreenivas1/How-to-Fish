# fist_punch_anim.py
# Authors the first-person punch animations in Blender and exports them as a
# Luau data module the fists viewmodel plays back. Same pipeline as the cast
# (rod_cast_anim.py) - run headless:
#
#   blender --background --python-exit-code 1 --python assets/fist_punch_anim.py -- src/Shared/Data/FistPunchAnim.luau
#
# What it produces:
#   - src/Shared/Data/FistPunchAnim.luau  two clips, "jab" (left leads) and
#                                         "cross" (right leads), each with a
#                                         track per fist
#   - assets/fist_punch.blend             a preview of the jab: block arms at
#                                         the in-game guard, camera at the
#                                         player's eye. Open, numpad 0, Space.
#
# Only the jab is keyframed. The cross is the jab mirrored across the
# centre of the screen (x -> -x, tracks swapped), done at export so the two
# punches are exactly symmetrical and there's one set of keys to tune.
#
# Authoring contract (FistsViewmodelController relies on these):
#   - Each clip has a track per fist ("left" / "right"), both always present:
#     the leading fist punches, the other pulls into a tighter guard for
#     weight. A track is a transform about THAT FIST (the hand's centre), in
#     camera space (Roblox +X right, +Y up, -Z forward; here Blender +X
#     right, +Z up, +Y forward - plain arithmetic in blender_to_roblox_*,
#     nothing passes through Studio's glTF importer). Pivoting at the fist
#     rather than the elbow means the location keys say exactly where the
#     fist goes on screen and the rotation keys only swing the forearm that
#     trails behind it - the fist itself never tumbles.
#   - Frame 0 and the last frame are both the identity (the guard), so a
#     finished punch needs no blend back. A punch interrupted by the next one
#     is blended by the Lua side.
#   - HIT_TIME is the moment of full extension - where a hit check belongs
#     once combat exists.

import math
import os
import sys

import bpy
from mathutils import Euler, Quaternion, Vector

# ---------------------------------------------------------------- parameters

FPS = 30

# The jab (left fist leads). One row per key:
#   (time, left (rotation, location), right (rotation, location))
#   location - studs, Blender axes (x right, y forward, z up): where the
#              fist goes. For the LEFT fist +x is inward, toward the centre
#              of the screen.
#   rotation - UNUSED by the game and kept at zero. In-game the forearm is
#              re-stretched each frame from a fixed elbow to wherever the
#              fist is (Viewmodel.placeArm), so the arm's direction is simply
#              elbow -> fist and a punch extends the arm instead of sliding
#              a rigid block forward (which dragged the block's cut-off
#              elbow end into view - the "back of the hand" the user kept
#              seeing). The preview .blend still moves rigid boxes, so it
#              shows the fist path, not the stretch.
#
# Fast: the whole thing is under a quarter of a second, so punches overlap
# and chain at the cooldown in Tuning.Combat (the user wanted ~3x the
# original rate).
JAB = [
    (0.00, ((0.0, 0.0, 0.0), (0.00, 0.00, 0.00)), ((0.0, 0.0, 0.0), (0.00, 0.00, 0.00))),  # guard
    (0.04, ((0.0, 0.0, 0.0), (-0.04, -0.10, 0.00)), ((0.0, 0.0, 0.0), (0.00, 0.03, 0.00))),  # load: a short pull back
    (0.09, ((0.0, 0.0, 0.0), (0.55, 1.60, 0.40)), ((0.0, 0.0, 0.0), (-0.10, -0.12, 0.08))),  # impact: fist out, just below centre; right tightens (HIT_TIME)
    (0.14, ((0.0, 0.0, 0.0), (0.42, 1.10, 0.30)), ((0.0, 0.0, 0.0), (-0.06, -0.08, 0.05))),  # retracting
    (0.23, ((0.0, 0.0, 0.0), (0.00, 0.00, 0.00)), ((0.0, 0.0, 0.0), (0.00, 0.00, 0.00))),  # guard
]

HIT_TIME = 0.09

# Preview-only approximation of the in-game guard, in ROBLOX camera axes,
# mirroring the constants at the top of FistsViewmodelController.luau (the
# right fist; the left is its mirror). This just makes the .blend show the
# punch from roughly the right place.
PREVIEW_FIST_POSITION = Vector((0.8, -1.1, -2.4))
PREVIEW_FOREARM_DIRECTION = Vector((-0.3, 0.62, -0.72)).normalized()
PREVIEW_HAND_SIZE = Vector((1.0, 0.3, 1.0))  # Viewmodel.HAND_SIZE
PREVIEW_LOWER_ARM_SIZE = Vector((1.0, 1.2, 1.0))  # Viewmodel.LOWER_ARM_SIZE


# ---------------------------------------------------------------- axes


def roblox_to_blender(v):
    return Vector((v.x, -v.z, v.y))


def blender_to_roblox_pos(v):
    return (v.x, v.z, -v.y)


def blender_to_roblox_quat(q):
    return (q.x, q.z, -q.y, q.w)


def mirror_x(frame):
    """Reflect a Roblox (x, y, z, qx, qy, qz, qw) frame across the screen's
    centre plane. A reflection flips handedness, so the rotation's axis
    mirrors AND its sense reverses: (qx, qy, qz) -> (qx, -qy, -qz)."""
    x, y, z, qx, qy, qz, qw = frame
    return (-x, y, z, qx, -qy, -qz, qw)


# ---------------------------------------------------------------- scene


def clear_scene():
    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.object.delete()
    for block in (bpy.data.meshes, bpy.data.materials, bpy.data.actions, bpy.data.cameras):
        for item in list(block):
            block.remove(item)


def make_empty(name, parent=None, location=(0, 0, 0)):
    empty = bpy.data.objects.new(name, None)
    empty.empty_display_type = "ARROWS"
    empty.empty_display_size = 0.4
    empty.location = location
    empty.parent = parent
    bpy.context.collection.objects.link(empty)
    return empty


def make_preview_camera():
    cam_data = bpy.data.cameras.new("PlayerEye")
    cam_data.lens_unit = "FOV"
    cam_data.angle = math.radians(70)
    cam = bpy.data.objects.new("PlayerEye", cam_data)
    cam.rotation_euler = Euler((math.radians(90), 0.0, 0.0), "XYZ")
    bpy.context.collection.objects.link(cam)
    bpy.context.scene.camera = cam
    return cam


def make_box(name, size, center, axis, color):
    """A block with its local +Z along `axis`, the way Roblox limbs stand
    along their own +Y. `size` is (width, length along the arm, depth)."""
    bpy.ops.mesh.primitive_cube_add(size=1.0, location=(0, 0, 0))
    box = bpy.context.active_object
    box.name = name
    box.scale = (size.x, size.z, size.y)
    box.rotation_mode = "QUATERNION"
    box.rotation_quaternion = Vector((0, 0, 1)).rotation_difference(axis)
    box.location = center

    mat = bpy.data.materials.new(name + "_Mat")
    mat.use_nodes = True
    mat.node_tree.nodes["Principled BSDF"].inputs["Base Color"].default_value = (*color, 1)
    box.data.materials.append(mat)
    for poly in box.data.polygons:
        poly.use_smooth = False
    return box


def build_preview_arm(side, sign, cast_anim):
    """Block lower arm + hand for one side at the guard, hung off that
    side's animated empty. `sign` mirrors the right fist's numbers."""
    mirror = Vector((sign, 1, 1))
    fist = roblox_to_blender(PREVIEW_FIST_POSITION * mirror)
    axis = roblox_to_blender((PREVIEW_FOREARM_DIRECTION * mirror).normalized())  # elbow -> fist

    hand_len = PREVIEW_HAND_SIZE.y
    arm_len = PREVIEW_LOWER_ARM_SIZE.y
    hand = make_box(f"{side}Hand", PREVIEW_HAND_SIZE, fist, axis, (0.86, 0.67, 0.55))
    arm = make_box(
        f"{side}LowerArm",
        PREVIEW_LOWER_ARM_SIZE,
        fist - axis * (hand_len / 2 + arm_len / 2),
        axis,
        (0.86, 0.67, 0.55),
    )

    bpy.context.view_layer.update()
    for obj in (hand, arm):
        world = obj.matrix_world.copy()
        obj.parent = cast_anim
        obj.matrix_parent_inverse = cast_anim.matrix_world.inverted()
        obj.matrix_world = world


def preview_fist(sign):
    """The pivot: the fist's centre at the guard."""
    mirror = Vector((sign, 1, 1))
    return roblox_to_blender(PREVIEW_FIST_POSITION * mirror)


# ---------------------------------------------------------------- animation


def fcurves_of(obj):
    action = obj.animation_data.action
    try:
        curves = list(action.fcurves)
        if curves:
            return curves
    except AttributeError:
        pass
    curves = []
    for layer in action.layers:
        for strip in layer.strips:
            for slot in action.slots:
                bag = strip.channelbag(slot)
                if bag:
                    curves.extend(bag.fcurves)
    return curves


def keyframe(empty, keys):
    for t, (rot_deg, loc) in keys:
        frame = round(t * FPS)
        empty.location = Vector(loc)
        empty.rotation_euler = Euler(tuple(math.radians(a) for a in rot_deg), "XYZ")
        empty.keyframe_insert(data_path="location", frame=frame)
        empty.keyframe_insert(data_path="rotation_euler", frame=frame)

    for fc in fcurves_of(empty):
        for kp in fc.keyframe_points:
            kp.interpolation = "BEZIER"
            kp.handle_left_type = "AUTO_CLAMPED"
            kp.handle_right_type = "AUTO_CLAMPED"
        fc.update()


def sample(empties, scene, last_frame):
    scene.frame_start = 0
    scene.frame_end = last_frame
    scene.render.fps = FPS

    tracks = {name: [] for name in empties}
    for f in range(last_frame + 1):
        scene.frame_set(f)
        for name, empty in empties.items():
            pos = blender_to_roblox_pos(empty.location.copy())
            quat = blender_to_roblox_quat(empty.rotation_euler.to_quaternion())
            tracks[name].append((*pos, *quat))
    scene.frame_set(0)
    return tracks


# ---------------------------------------------------------------- export


def fmt(n):
    s = f"{n:.4f}"
    return "0.0000" if s == "-0.0000" else s


def write_track(lines, name, frames):
    lines.append(f"\t\t\t{name} = {{")
    for frame in frames:
        lines.append("\t\t\t\t{ " + ", ".join(fmt(n) for n in frame) + " },")
    lines.append("\t\t\t},")


def write_luau(path, clips):
    duration = JAB[-1][0]
    lines = [
        "--!nonstrict",
        "-- FistPunchAnim.luau",
        "-- GENERATED by assets/fist_punch_anim.py - do not hand-edit. Change the",
        "-- JAB table in that script and re-run it (see assets/README.md).",
        "--",
        "-- First-person punches. Each clip has a track per fist, each a transform",
        "-- about that fist's elbow in camera space (+X right, +Y up, -Z forward),",
        "-- one { x, y, z, qx, qy, qz, qw } CFrame argument list per frame. Both",
        "-- tracks start and end at the identity (the guard). \"cross\" is \"jab\"",
        "-- mirrored across the centre of the screen. FistsViewmodelController",
        "-- plays them.",
        "",
        "local FistPunchAnim = {}",
        "",
        f"FistPunchAnim.FPS = {FPS}",
        "",
        "-- The order successive punches cycle through.",
        'FistPunchAnim.SEQUENCE = { "jab", "cross" }',
        "",
        "FistPunchAnim.CLIPS = {",
    ]
    for name, (lead, tracks) in clips.items():
        lines.append(f"\t{name} = {{")
        lines.append(f'\t\tlead = "{lead}",')
        lines.append(f"\t\tDURATION = {duration},")
        lines.append(f"\t\tHIT_TIME = {HIT_TIME},")
        lines.append("\t\tTRACKS = {")
        write_track(lines, "left", tracks["left"])
        write_track(lines, "right", tracks["right"])
        lines.append("\t\t},")
        lines.append("\t},")
    lines += ["}", "", "return FistPunchAnim", ""]

    with open(path, "w", encoding="utf-8", newline="\n") as handle:
        handle.write("\n".join(lines))


def main():
    args = sys.argv[sys.argv.index("--") + 1 :]
    out_path = args[0]
    blend_path = args[1] if len(args) > 1 else os.path.join(os.path.dirname(os.path.abspath(__file__)), "fist_punch.blend")

    clear_scene()
    scene = bpy.context.scene
    make_preview_camera()

    empties = {}
    for side, sign in (("Left", -1), ("Right", 1)):
        pivot = make_empty(f"{side}Pivot", location=preview_fist(sign))
        anim = make_empty(f"{side}Anim", parent=pivot)
        build_preview_arm(side, sign, anim)
        empties[side.lower()] = anim

    keyframe(empties["left"], [(t, left) for t, left, _ in JAB])
    keyframe(empties["right"], [(t, right) for t, _, right in JAB])

    last_frame = round(JAB[-1][0] * FPS)
    jab = sample(empties, scene, last_frame)
    cross = {
        "left": [mirror_x(f) for f in jab["right"]],
        "right": [mirror_x(f) for f in jab["left"]],
    }

    write_luau(out_path, {"jab": ("left", jab), "cross": ("right", cross)})
    bpy.ops.wm.save_as_mainfile(filepath=os.path.abspath(blend_path))

    print(f"[fist_punch_anim] exported {out_path}: {last_frame + 1} frames at {FPS} fps, hit at {HIT_TIME}s")
    print(f"[fist_punch_anim] preview saved to {blend_path}")


main()
