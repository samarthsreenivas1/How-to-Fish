# rod_cast_anim.py
# Authors the first-person cast animation in Blender and exports it as a
# Luau data module the viewmodel plays back. Same pipeline as the meshes -
# run headless:
#
#   blender --background --python-exit-code 1 --python assets/rod_cast_anim.py -- src/Shared/Data/RodCastAnim.luau
#
# What it produces:
#   - src/Shared/Data/RodCastAnim.luau   the sampled clip (one CFrame per frame)
#   - assets/rod_cast.blend              a preview scene: open it and press
#                                        Space to watch the rod swing
#
# Why a data module and not a Roblox Animation asset: the first-person rod is
# a code-posed viewmodel (RodViewmodelController) with no rig and no Motor6D
# joints, so there is nothing for an Animator to drive. Exporting the curve
# as plain numbers keeps the whole thing in the repo, deterministic, and
# free of the manual upload-and-paste-an-asset-id step.
#
# Authoring contract (RodViewmodelController relies on these, keep them true):
#   - The clip is a transform of the WHOLE viewmodel (rod + hand + forearm)
#     about a pivot at the player's elbow. The Lua side finds the elbow from
#     the actual character parts; the preview scene only approximates it.
#   - Axes are the camera's: Roblox +X right, +Y up, -Z forward. In Blender
#     that is +X right, +Z up, +Y forward (Blender y -> Roblox -z). This is
#     plain arithmetic done below in blender_to_roblox_*; nothing here passes
#     through Studio's glTF importer, so the 180-degree flip context.md
#     describes for imported meshes does NOT apply to this file.
#   - Frame 0 must be the identity (the idle pose). The clip's last frame is
#     HELD for as long as the cast is out - so it is the "line's in the
#     water" pose, not a return to idle. The Lua side eases back to idle when
#     the cast ends.
#   - RELEASE_TIME is when the line leaves the rod tip. FishingController
#     launches the bobber at that moment, so it should sit at the fastest
#     forward point of the whip.

import math
import os
import sys

import bpy
from mathutils import Euler, Vector

# ---------------------------------------------------------------- parameters

FPS = 30

# The animation. One row per key: (time in seconds, rotation, location).
#   rotation - Euler XYZ in degrees, about the elbow pivot. About X: positive
#              tips the rod back over the shoulder, negative whips it forward.
#              About Z: positive swings the tip toward the centre of the
#              screen, negative out to the right.
#   location - studs, Blender axes (x right, y forward, z up).
KEYS = [
    (0.00, (0.0, 0.0, 0.0), (0.0, 0.00, 0.00)),  # idle
    (0.20, (34.0, 0.0, -8.0), (0.0, -0.15, 0.12)),  # wind-up: back over the shoulder, lifted, a touch outward
    (0.30, (-38.0, 0.0, 2.0), (0.0, 0.30, -0.05)),  # release: the whip forward (RELEASE_TIME)
    (0.40, (-46.0, 0.0, 3.0), (0.0, 0.22, -0.15)),  # follow-through overshoot
    (0.62, (-16.0, 0.0, 0.0), (0.0, 0.05, -0.02)),  # recoil back up
    (0.90, (-20.0, 0.0, 0.0), (0.0, 0.00, -0.04)),  # hold: lowered toward the water (held while reeling)
]

RELEASE_TIME = 0.30

# Preview-only approximation of the in-game pose, in ROBLOX camera axes,
# mirroring the constants at the top of RodViewmodelController.luau. The
# game computes the real pivot from the character's arm parts; these just
# make the saved .blend show the swing from roughly the right place.
PREVIEW_GRIP_POSITION = Vector((1.45, -1.6, -2.6))
PREVIEW_FOREARM_DIRECTION = Vector((-0.25, 0.55, -0.8)).normalized()
PREVIEW_ARM_LENGTH = 1.3  # hand half-height + forearm length, studs
PREVIEW_ROD_PITCH = 58.0  # degrees above the horizon
PREVIEW_ROD_YAW = 3.0
PREVIEW_GRIP_ON_ROD = 0.95  # GRIP_CENTER in rod_gen.py


# ---------------------------------------------------------------- axes


def roblox_to_blender(v):
    """Roblox camera space (x right, y up, -z forward) -> Blender (x right,
    y forward, z up)."""
    return Vector((v.x, -v.z, v.y))


def blender_to_roblox_pos(v):
    return (v.x, v.z, -v.y)


def blender_to_roblox_quat(q):
    """Blender (w, x, y, z) -> Roblox (qx, qy, qz, qw). The basis change is a
    proper rotation, so the quaternion's axis just goes through the same
    axis mapping as a position and the angle is untouched."""
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
    """At the player's eye, looking along Blender +Y (= Roblox -Z, forward),
    so the viewport through it matches what the player sees."""
    cam_data = bpy.data.cameras.new("PlayerEye")
    cam_data.lens_unit = "FOV"
    cam_data.angle = math.radians(70)
    cam = bpy.data.objects.new("PlayerEye", cam_data)
    cam.rotation_euler = Euler((math.radians(90), 0.0, 0.0), "XYZ")
    bpy.context.collection.objects.link(cam)
    bpy.context.scene.camera = cam
    return cam


def import_rod_preview():
    """Brings the real twig rod mesh in under one empty so the preview shows
    the actual rod. Falls back to a plain cylinder if the .glb is missing or
    the importer balks - the animation data doesn't depend on it."""
    root = make_empty("RodPreview")
    root.empty_display_size = 0.2

    glb = os.path.join(os.path.dirname(os.path.abspath(__file__)), "twig_rod.glb")
    imported = []
    try:
        bpy.ops.object.select_all(action="DESELECT")
        bpy.ops.import_scene.gltf(filepath=glb)
        imported = [o for o in bpy.context.selected_objects if o.parent is None]
    except Exception as err:  # noqa: BLE001 - any importer failure means "use the stand-in"
        print(f"[rod_cast_anim] could not import {glb} for the preview ({err}); using a cylinder")

    if not imported:
        bpy.ops.mesh.primitive_cylinder_add(vertices=6, radius=0.12, depth=7.0, location=(0, 0, 3.5))
        stand_in = bpy.context.active_object
        stand_in.name = "Rod_StandIn"
        imported = [stand_in]

    for obj in imported:
        obj.parent = root
    return root


def place_rod_preview(rod_root, cast_anim):
    """Puts the rod where the viewmodel holds it and hangs it off the animated
    empty, so the keyframes move it about the elbow exactly as in-game."""
    grip = roblox_to_blender(PREVIEW_GRIP_POSITION)

    # Rod axis is +Z after import. Tip forward (+Y) and up by the pitch.
    rot = Euler((math.radians(-(90.0 - PREVIEW_ROD_PITCH)), 0.0, math.radians(PREVIEW_ROD_YAW)), "XYZ")
    axis = rot.to_matrix() @ Vector((0.0, 0.0, 1.0))
    butt = grip - axis * PREVIEW_GRIP_ON_ROD

    rod_root.rotation_euler = rot
    rod_root.location = butt

    bpy.context.view_layer.update()
    world = rod_root.matrix_world.copy()
    rod_root.parent = cast_anim
    rod_root.matrix_parent_inverse = cast_anim.matrix_world.inverted()
    rod_root.matrix_world = world


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


def keyframe(cast_anim):
    for t, rot_deg, loc in KEYS:
        frame = round(t * FPS)
        cast_anim.location = Vector(loc)
        cast_anim.rotation_euler = Euler(tuple(math.radians(a) for a in rot_deg), "XYZ")
        cast_anim.keyframe_insert(data_path="location", frame=frame)
        cast_anim.keyframe_insert(data_path="rotation_euler", frame=frame)

    # Smooth, clamped Bezier everywhere: no overshoot between keys, the ease
    # in and out of each pose comes for free, and the result is the same on
    # every run regardless of the user's keyframe preferences.
    for fc in fcurves_of(cast_anim):
        for kp in fc.keyframe_points:
            kp.interpolation = "BEZIER"
            kp.handle_left_type = "AUTO_CLAMPED"
            kp.handle_right_type = "AUTO_CLAMPED"
        fc.update()


def sample(cast_anim, scene):
    last_frame = round(KEYS[-1][0] * FPS)
    scene.frame_start = 0
    scene.frame_end = last_frame
    scene.render.fps = FPS

    frames = []
    for f in range(last_frame + 1):
        scene.frame_set(f)
        pos = blender_to_roblox_pos(cast_anim.location.copy())
        quat = blender_to_roblox_quat(cast_anim.rotation_euler.to_quaternion())
        frames.append((*pos, *quat))
    scene.frame_set(0)
    return frames


# ---------------------------------------------------------------- export


def fmt(n):
    s = f"{n:.4f}"
    if s == "-0.0000":
        s = "0.0000"
    return s


def write_luau(path, frames):
    duration = KEYS[-1][0]
    lines = [
        "--!nonstrict",
        "-- RodCastAnim.luau",
        "-- GENERATED by assets/rod_cast_anim.py - do not hand-edit. Change the",
        "-- KEYS table in that script and re-run it (see assets/README.md).",
        "--",
        "-- The first-person cast: one transform per frame, applied to the whole",
        "-- rod viewmodel (rod + hand + forearm) about a pivot at the elbow, in",
        "-- camera space (+X right, +Y up, -Z forward). Each frame is",
        "-- { x, y, z, qx, qy, qz, qw } - a CFrame.new(...) argument list.",
        "-- Frame 1 is the identity; the last frame is held while a cast is out.",
        "-- RodViewmodelController plays it.",
        "",
        "local RodCastAnim = {}",
        "",
        f"RodCastAnim.FPS = {FPS}",
        f"RodCastAnim.DURATION = {duration}",
        "",
        "-- When the line leaves the rod tip. FishingController launches the bobber",
        "-- at this point in the clip rather than on the click itself.",
        f"RodCastAnim.RELEASE_TIME = {RELEASE_TIME}",
        "",
        "RodCastAnim.FRAMES = {",
    ]
    for frame in frames:
        lines.append("\t{ " + ", ".join(fmt(n) for n in frame) + " },")
    lines += ["}", "", "return RodCastAnim", ""]

    with open(path, "w", encoding="utf-8", newline="\n") as handle:
        handle.write("\n".join(lines))


def main():
    args = sys.argv[sys.argv.index("--") + 1 :]
    out_path = args[0]
    blend_path = args[1] if len(args) > 1 else os.path.join(os.path.dirname(os.path.abspath(__file__)), "rod_cast.blend")

    clear_scene()
    scene = bpy.context.scene

    make_preview_camera()

    # Static pivot at the elbow; the animated empty hangs off it at identity,
    # so what we sample is purely the cast's own motion.
    elbow = PREVIEW_GRIP_POSITION - PREVIEW_FOREARM_DIRECTION * PREVIEW_ARM_LENGTH
    cast_pivot = make_empty("CastPivot", location=roblox_to_blender(elbow))
    cast_anim = make_empty("CastAnim", parent=cast_pivot)

    rod_root = import_rod_preview()
    place_rod_preview(rod_root, cast_anim)

    keyframe(cast_anim)
    frames = sample(cast_anim, scene)
    write_luau(out_path, frames)

    bpy.ops.wm.save_as_mainfile(filepath=os.path.abspath(blend_path))

    print(f"[rod_cast_anim] exported {out_path}: {len(frames)} frames at {FPS} fps, release at {RELEASE_TIME}s")
    print(f"[rod_cast_anim] preview saved to {blend_path}")


main()
