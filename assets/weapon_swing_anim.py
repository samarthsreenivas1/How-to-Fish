# weapon_swing_anim.py
# Authors the first-person melee weapon swings in Blender and exports them
# as a Luau data module the weapon viewmodel plays back. Same pipeline as the
# cast (rod_cast_anim.py) and the punches (fist_punch_anim.py) - run headless:
#
#   blender --background --python-exit-code 1 --python assets/weapon_swing_anim.py -- src/Shared/Data/WeaponSwingAnim.luau
#
# What it produces:
#   - src/Shared/Data/WeaponSwingAnim.luau   one clip per entry in CLIPS
#                                            ("chop" for the club, "slash" for
#                                            the blade), sampled per frame
#   - assets/weapon_swing.blend              a preview of the LAST clip in
#                                            CLIPS (the chop): a stand-in
#                                            weapon + block arm at the in-game
#                                            pose, camera at the player's eye.
#                                            Open, numpad 0, Space.
#
# Authoring contract (WeaponViewmodelController relies on these):
#   - A clip is a transform of the WHOLE viewmodel (weapon + hand + forearm)
#     about a pivot at the player's elbow - exactly the cast's contract, so
#     the same Rig:pin path plays it. The Lua side finds the elbow from the
#     built arm; the preview scene only approximates it.
#   - Axes are the camera's: Roblox +X right, +Y up, -Z forward. In Blender
#     that is +X right, +Z up, +Y forward (Blender y -> Roblox -z), converted
#     by plain arithmetic below; nothing passes through Studio's importer.
#   - Frame 0 AND the last frame are the identity (the idle hold), so a
#     finished swing needs no blend back. A swing interrupted by the next one
#     is blended by the Lua side.
#   - HIT_TIME is the moment the weapon is at the bottom of its arc - where
#     CombatController asks the server to land the hit. The weapon row's
#     cooldown should be at least this long.

import math
import os
import sys

import bpy
from mathutils import Euler, Vector

# ---------------------------------------------------------------- parameters

FPS = 30

# Each clip: one row per key, (time in seconds, rotation, location).
#   rotation - Euler XYZ in degrees, about the elbow pivot. About X: positive
#              tips the weapon back over the shoulder, negative swings it
#              down and forward. About Z: positive swings the tip toward the
#              centre of the screen, negative out to the right.
#   location - studs, Blender axes (x right, y forward, z up).
CLIPS = {
    # The blade: a quick cut from the right across the centre of the screen.
    "slash": {
        "HIT_TIME": 0.10,
        "KEYS": [
            (0.00, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),  # idle
            (0.05, (12.0, 0.0, -18.0), (0.12, -0.10, 0.06)),  # wind: tip out to the right, pulled back
            (0.10, (-24.0, 0.0, 36.0), (-0.30, 0.32, -0.10)),  # cut: through the centre, forward (HIT_TIME)
            (0.15, (-30.0, 0.0, 44.0), (-0.36, 0.26, -0.16)),  # follow-through
            (0.24, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),  # idle
        ],
    },
    # The club: raise it back over the shoulder, then chop down and forward.
    "chop": {
        "HIT_TIME": 0.18,
        "KEYS": [
            (0.00, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),  # idle
            (0.08, (30.0, 0.0, -10.0), (0.06, -0.16, 0.16)),  # wind-up: back and lifted
            (0.18, (-54.0, 0.0, 18.0), (-0.10, 0.36, -0.22)),  # impact: chopped down toward the centre (HIT_TIME)
            (0.26, (-60.0, 0.0, 20.0), (-0.10, 0.30, -0.32)),  # follow-through overshoot
            (0.45, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),  # idle
        ],
    },
}

# Preview-only approximation of the in-game pose, in ROBLOX camera axes,
# mirroring the constants at the top of WeaponViewmodelController.luau. The
# game computes the real pivot from the built arm; these just make the saved
# .blend show the swing from roughly the right place.
PREVIEW_GRIP_POSITION = Vector((1.35, -1.5, -2.5))
PREVIEW_FOREARM_DIRECTION = Vector((-0.25, 0.55, -0.8)).normalized()
PREVIEW_ARM_LENGTH = 1.35  # hand half-height + forearm length, studs
PREVIEW_WEAPON_PITCH = 62.0  # degrees above the horizon
PREVIEW_WEAPON_YAW = 8.0
PREVIEW_WEAPON_LENGTH = 3.4  # the club's row
PREVIEW_GRIP_ON_WEAPON = 0.7
PREVIEW_HAND_SIZE = Vector((1.0, 0.3, 1.0))  # Viewmodel.HAND_SIZE
PREVIEW_LOWER_ARM_SIZE = Vector((1.0, 1.2, 1.0))  # Viewmodel.LOWER_ARM_SIZE


# ---------------------------------------------------------------- axes


def roblox_to_blender(v):
    return Vector((v.x, -v.z, v.y))


def blender_to_roblox_pos(v):
    return (v.x, v.z, -v.y)


def blender_to_roblox_quat(q):
    return (q.x, q.z, -q.y, q.w)


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
    empty.empty_display_size = 0.5
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
    along their own +Y. `size` is (width, length along the axis, depth)."""
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


def parent_keep_world(obj, parent):
    bpy.context.view_layer.update()
    world = obj.matrix_world.copy()
    obj.parent = parent
    obj.matrix_parent_inverse = parent.matrix_world.inverted()
    obj.matrix_world = world


def build_preview(swing_anim):
    """A stand-in club (haft + head) at the in-game hold, plus the right
    block arm closing on its grip, all hung off the animated empty."""
    grip = roblox_to_blender(PREVIEW_GRIP_POSITION)
    rot = Euler(
        (math.radians(-(90.0 - PREVIEW_WEAPON_PITCH)), 0.0, math.radians(PREVIEW_WEAPON_YAW)),
        "XYZ",
    )
    axis = rot.to_matrix() @ Vector((0.0, 0.0, 1.0))
    butt = grip - axis * PREVIEW_GRIP_ON_WEAPON

    haft_len = PREVIEW_WEAPON_LENGTH - 1.3
    haft = make_box("Weapon_Haft", Vector((0.32, haft_len, 0.32)), butt + axis * (haft_len / 2), axis, (0.59, 0.44, 0.28))
    head = make_box(
        "Weapon_Head",
        Vector((0.85, 1.3, 0.85)),
        butt + axis * (PREVIEW_WEAPON_LENGTH - 0.65),
        axis,
        (0.46, 0.34, 0.21),
    )

    arm_axis = roblox_to_blender(PREVIEW_FOREARM_DIRECTION)  # elbow -> hand
    hand_len = PREVIEW_HAND_SIZE.y
    arm_len = PREVIEW_LOWER_ARM_SIZE.y
    hand = make_box("RightHand", PREVIEW_HAND_SIZE, grip, arm_axis, (0.86, 0.67, 0.55))
    arm = make_box(
        "RightLowerArm",
        PREVIEW_LOWER_ARM_SIZE,
        grip - arm_axis * (hand_len / 2 + arm_len / 2),
        arm_axis,
        (0.86, 0.67, 0.55),
    )

    for obj in (haft, head, hand, arm):
        parent_keep_world(obj, swing_anim)


# ---------------------------------------------------------------- animation


def fcurves_of(obj):
    """Action F-curves, tolerant of the 4.4+ slotted-action layout."""
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


def keyframe(swing_anim, keys):
    swing_anim.animation_data_clear()
    for t, rot_deg, loc in keys:
        frame = round(t * FPS)
        swing_anim.location = Vector(loc)
        swing_anim.rotation_euler = Euler(tuple(math.radians(a) for a in rot_deg), "XYZ")
        swing_anim.keyframe_insert(data_path="location", frame=frame)
        swing_anim.keyframe_insert(data_path="rotation_euler", frame=frame)

    for fc in fcurves_of(swing_anim):
        for kp in fc.keyframe_points:
            kp.interpolation = "BEZIER"
            kp.handle_left_type = "AUTO_CLAMPED"
            kp.handle_right_type = "AUTO_CLAMPED"
        fc.update()


def sample(swing_anim, scene, keys):
    last_frame = round(keys[-1][0] * FPS)
    scene.frame_start = 0
    scene.frame_end = last_frame
    scene.render.fps = FPS

    frames = []
    for f in range(last_frame + 1):
        scene.frame_set(f)
        pos = blender_to_roblox_pos(swing_anim.location.copy())
        quat = blender_to_roblox_quat(swing_anim.rotation_euler.to_quaternion())
        frames.append((*pos, *quat))
    scene.frame_set(0)
    return frames


# ---------------------------------------------------------------- export


def fmt(n):
    s = f"{n:.4f}"
    return "0.0000" if s == "-0.0000" else s


def write_luau(path, clips):
    lines = [
        "--!nonstrict",
        "-- WeaponSwingAnim.luau",
        "-- GENERATED by assets/weapon_swing_anim.py - do not hand-edit. Change the",
        "-- CLIPS table in that script and re-run it (see assets/README.md).",
        "--",
        "-- First-person melee swings, one clip per weapon `swing` name",
        "-- (Weapons.luau). Each is a transform of the whole weapon viewmodel",
        "-- (weapon + hand + forearm) about a pivot at the elbow, in camera space",
        "-- (+X right, +Y up, -Z forward), one { x, y, z, qx, qy, qz, qw } CFrame",
        "-- argument list per frame. First and last frames are the identity (the",
        "-- idle hold). WeaponViewmodelController plays them.",
        "",
        "local WeaponSwingAnim = {}",
        "",
        f"WeaponSwingAnim.FPS = {FPS}",
        "",
        "WeaponSwingAnim.CLIPS = {",
    ]
    for name, (hit_time, duration, frames) in clips.items():
        lines.append(f"\t{name} = {{")
        lines.append(f"\t\tDURATION = {duration},")
        lines.append(f"\t\tHIT_TIME = {hit_time},")
        lines.append("\t\tFRAMES = {")
        for frame in frames:
            lines.append("\t\t\t{ " + ", ".join(fmt(n) for n in frame) + " },")
        lines.append("\t\t},")
        lines.append("\t},")
    lines += ["}", "", "return WeaponSwingAnim", ""]

    with open(path, "w", encoding="utf-8", newline="\n") as handle:
        handle.write("\n".join(lines))


def main():
    args = sys.argv[sys.argv.index("--") + 1 :]
    out_path = args[0]
    blend_path = args[1] if len(args) > 1 else os.path.join(os.path.dirname(os.path.abspath(__file__)), "weapon_swing.blend")

    clear_scene()
    scene = bpy.context.scene
    make_preview_camera()

    # Static pivot at the elbow; the animated empty hangs off it at identity,
    # so what we sample is purely the swing's own motion.
    elbow = PREVIEW_GRIP_POSITION - PREVIEW_FOREARM_DIRECTION * PREVIEW_ARM_LENGTH
    swing_pivot = make_empty("SwingPivot", location=roblox_to_blender(elbow))
    swing_anim = make_empty("SwingAnim", parent=swing_pivot)
    build_preview(swing_anim)

    exported = {}
    for name, clip in CLIPS.items():
        keyframe(swing_anim, clip["KEYS"])
        frames = sample(swing_anim, scene, clip["KEYS"])
        exported[name] = (clip["HIT_TIME"], clip["KEYS"][-1][0], frames)
        print(f"[weapon_swing_anim] {name}: {len(frames)} frames at {FPS} fps, hit at {clip['HIT_TIME']}s")

    write_luau(out_path, exported)
    bpy.ops.wm.save_as_mainfile(filepath=os.path.abspath(blend_path))

    print(f"[weapon_swing_anim] exported {out_path}")
    print(f"[weapon_swing_anim] preview saved to {blend_path}")


main()
