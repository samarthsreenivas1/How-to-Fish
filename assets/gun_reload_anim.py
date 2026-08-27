# gun_reload_anim.py
# Authors the first-person GUN RELOAD animations in Blender and exports them
# as a Luau data module (same pipeline family as weapon_swing_anim.py /
# fist_punch_anim.py). Run headless:
#
#   blender --background --python-exit-code 1 --python assets/gun_reload_anim.py -- src/Shared/Data/GunReloadAnim.luau
#   blender --background --python-exit-code 1 --python assets/gun_reload_anim.py -- src/Shared/Data/GunReloadAnim.luau stills /tmp/claude-501/reload_stills
#
# The second form also renders a folder of per-clip filmstrip stills (6 frames
# per clip, stand-in gun/mag/hand boxes at the in-game hold) for design review
# without booting the game.
#
# What it produces: src/Shared/Data/GunReloadAnim.luau - one MULTI-TRACK clip
# per WeaponPack gun VARIANT (plus "Generic", the fallback for any variant
# without its own). WeaponViewmodelController plays them during a reload,
# time-scaled so the clip always fills the row's server-enforced
# ranged.reloadTime exactly (reloadTime 0 guns - bows, muzzle-loaders - play
# theirs after every shot inside the cooldown instead).
#
# Authoring contract (WeaponViewmodelController relies on these):
#   - Up to four TRACKS per clip, each keys of (time, rotation, location):
#       weapon  the WHOLE viewmodel (gun + right arm) about the right elbow -
#               exactly the swing clips' contract.
#       mag     the gun's Weapon_Mag part, LOCAL about its own home: rotation
#               spins the part in place, location translates it in camera
#               axes. This is the magazine / arrow / shell the hand handles.
#       action  the gun's Weapon_Action part, same local semantics - the bolt
#               throw, the charging handle, the revolver cylinder swing/spin.
#       hand    the LEFT block hand + forearm (built parked off-screen), same
#               local-about-home semantics. Author it to MEET the mag: rise to
#               the gun, travel WITH the mag while it is out (same velocities,
#               that is what sells "the hand carries it"), push it home, park.
#   - Axes are the camera's, via the same Blender convention as the swing
#     script: x right, y forward, z up; rotations Euler XYZ in degrees.
#   - Every track's first AND last key are the identity - a finished reload
#     leaves the gun exactly held again; interrupts blend on the Lua side.
#   - DURATION is the authored length; playback time-scales it to the row's
#     reloadTime, so author at a natural tempo and let scaling fit the row.
#     Keep key SPACING proportional - a beat that reads at 1.0x reads at 0.8x.
#   - The hand starts PARKED (the engine holds it off-screen between reloads);
#     key it up into frame early and back down by the end.
#
# Colours and shapes here are preview-only stand-ins; the game animates the
# real WeaponPack parts.

import math
import os
import sys

import bpy
from mathutils import Euler, Vector

TAU = math.tau
FPS = 30

# ---------------------------------------------------------------- clips
#
# One entry per gun variant. Families for reference while authoring:
#   auto mag-swap: CinderlockCarbine VulkanRepeater RiptideSmg CycloneRifle
#   box-mag precision: GloomcallerDmr | bolt single: FrostboreRifle
#   revolver: FrostbiteRevolver | 5-chamber: ThunderheadCannon
#   break/muzzle shotguns: BasaltScattergun GraveBlunderbuss
#   lever+tube: PhantomRepeater
#   per-shot loaders (reloadTime 0): BogwoodBow (arrow), GatorjawCrossbow
#   (bolt), MireFlintlock (powder + ram), AbyssalHarpooner (new iron)

CLIPS = {
    # Fallback for any variant with no clip of its own: the gun dips right
    # while the off-hand fusses at it, then levels back. Deliberately plain.
    "Generic": {
        "DURATION": 1.0,
        "TRACKS": {
            "weapon": [
                (0.00, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),
                (0.25, (-8.0, 10.0, -14.0), (0.10, -0.14, -0.16)),
                (0.75, (-6.0, 8.0, -12.0), (0.08, -0.12, -0.14)),
                (1.00, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),
            ],
            "hand": [
                (0.00, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),
                (0.25, (0.0, 0.0, 0.0), (0.10, 0.35, 3.00)),
                (0.75, (10.0, 0.0, 0.0), (0.16, 0.30, 2.90)),
                (1.00, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),
            ],
        },
    },

    # AK-flavored auto (0.8s): cant the gun to present the mag well, the hand
    # rips the mag DOWN and out of frame, a fresh one rides the same hand back
    # up, seats with an overshoot shove, and the charging handle gets flicked.
    "CinderlockCarbine": {
        "DURATION": 0.8,
        "TRACKS": {
            "weapon": [
                (0.00, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),
                (0.12, (-6.0, 14.0, -20.0), (0.12, -0.10, -0.10)),  # cant right, mag well shown
                (0.55, (-6.0, 14.0, -20.0), (0.12, -0.10, -0.10)),  # held through the swap
                (0.68, (-2.0, 4.0, -6.0), (0.04, -0.02, -0.04)),  # levelling as the handle is worked
                (0.80, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),
            ],
            "mag": [
                (0.00, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),
                (0.14, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),  # hand arrives first
                (0.22, (14.0, 0.0, 0.0), (0.02, 0.06, -0.55)),  # rocked free, dropping
                (0.34, (30.0, 0.0, 0.0), (0.10, 0.20, -2.60)),  # ripped down out of frame WITH the hand
                (0.44, (-18.0, 0.0, 0.0), (0.06, 0.24, -2.40)),  # the fresh mag rides back up
                (0.54, (-6.0, 0.0, 0.0), (0.01, 0.03, -0.16)),  # offered to the well
                (0.585, (0.0, 0.0, 0.0), (0.00, 0.00, 0.06)),  # seated - a shove past home
                (0.62, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),
                (0.80, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),
            ],
            "hand": [
                (0.00, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),
                (0.14, (0.0, 0.0, 0.0), (-0.02, 0.02, 0.04)),  # closes on the mag
                (0.22, (14.0, 0.0, 0.0), (0.00, 0.08, -0.51)),  # same path as the mag...
                (0.34, (30.0, 0.0, 0.0), (0.08, 0.22, -2.56)),  # ...all the way down
                (0.44, (-18.0, 0.0, 0.0), (0.04, 0.26, -2.36)),  # ...and back with the fresh one
                (0.54, (-6.0, 0.0, 0.0), (-0.01, 0.05, -0.12)),
                (0.585, (0.0, 0.0, 0.0), (-0.02, 0.02, 0.10)),  # the seating shove
                (0.64, (0.0, -20.0, 0.0), (0.30, -0.25, 0.35)),  # up to the charging handle
                (0.70, (0.0, -20.0, 0.0), (0.30, -0.55, 0.35)),  # yanks it back
                (0.80, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),
            ],
            "action": [
                (0.00, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),
                (0.64, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),
                (0.70, (0.0, 0.0, 0.0), (0.00, -0.30, 0.00)),  # charging handle back
                (0.75, (0.0, 0.0, 0.0), (0.00, 0.04, 0.00)),  # slams home
                (0.80, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),
            ],
        },
    },

    # Revolver (1.8s): muzzle tips up-left as the cylinder swings OUT, a wrist
    # flick ejects (the whole gun snaps up), the hand feeds fresh rounds while
    # the cylinder slow-rolls, then it snaps shut with a flick and settles.
    "FrostbiteRevolver": {
        "DURATION": 1.8,
        "TRACKS": {
            "weapon": [
                (0.00, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),
                (0.20, (18.0, -22.0, 16.0), (-0.14, -0.16, 0.10)),  # rolled left, presented
                (0.42, (46.0, -26.0, 18.0), (-0.16, -0.22, 0.26)),  # muzzle up - the eject flick
                (0.55, (24.0, -24.0, 16.0), (-0.15, -0.18, 0.12)),  # back to the feed pose
                (1.32, (22.0, -22.0, 15.0), (-0.14, -0.17, 0.11)),  # held there while loading
                (1.50, (6.0, -6.0, 4.0), (-0.04, -0.05, 0.03)),  # the closing wrist flick
                (1.62, (-4.0, 3.0, -3.0), (0.02, 0.02, -0.02)),  # snap-shut overshoot
                (1.80, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),
            ],
            "action": [  # the cylinder
                (0.00, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),
                (0.14, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),
                (0.24, (0.0, 42.0, 0.0), (-0.16, 0.00, -0.04)),  # swings out of the frame-left
                (0.42, (0.0, 46.0, -30.0), (-0.18, 0.00, -0.05)),  # tips with the eject
                (0.60, (0.0, 44.0, -120.0), (-0.17, 0.00, -0.04)),  # slow roll while feeding...
                (1.30, (0.0, 44.0, -420.0), (-0.17, 0.00, -0.04)),  # ...round after round
                (1.50, (0.0, 40.0, -540.0), (-0.15, 0.00, -0.03)),
                (1.60, (0.0, 0.0, -540.0), (0.00, 0.00, 0.00)),  # snapped shut
                (1.80, (0.0, 0.0, -720.0), (0.00, 0.00, 0.00)),  # settles on a full turn
            ],
            "hand": [
                (0.00, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),
                (0.20, (0.0, 0.0, 0.0), (-0.10, 0.10, 0.30)),  # cups under the frame
                (0.55, (-20.0, 0.0, 0.0), (-0.14, 0.16, 0.44)),  # thumb at the cylinder
                (0.75, (-30.0, 0.0, 0.0), (-0.10, 0.05, -0.60)),  # down for rounds
                (0.95, (-16.0, 0.0, 0.0), (-0.13, 0.18, 0.40)),  # feeds them in
                (1.12, (-30.0, 0.0, 0.0), (-0.10, 0.05, -0.60)),  # second dip
                (1.30, (-16.0, 0.0, 0.0), (-0.13, 0.18, 0.40)),  # last rounds in
                (1.52, (0.0, 0.0, 0.0), (-0.12, 0.10, 0.20)),  # palm closes it
                (1.80, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),
            ],
        },
    },

    # Bow nock (0.42s, plays after every shot inside the 0.45 cooldown): the
    # hand and a fresh arrow (the bow's Weapon_Mag) sweep up together from the
    # low quiver line to the string, a tiny settle-draw, and the hand drops.
    "BogwoodBow": {
        "DURATION": 0.42,
        "TRACKS": {
            "weapon": [
                (0.00, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),
                (0.16, (-4.0, 6.0, -8.0), (0.05, -0.04, -0.05)),  # bow tips to meet the arrow
                (0.30, (2.0, -2.0, 3.0), (-0.02, 0.03, 0.02)),  # settle-draw tension
                (0.42, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),
            ],
            "mag": [  # the arrow
                (0.00, (0.0, 0.0, 0.0), (0.30, 0.10, -2.40)),  # already off-frame low (just loosed)
                (0.14, (-24.0, 0.0, 10.0), (0.22, 0.16, -1.10)),  # swept up from the quiver line
                (0.26, (-6.0, 0.0, 2.0), (0.04, 0.04, -0.14)),  # laid to the string
                (0.31, (0.0, 0.0, 0.0), (0.00, -0.05, 0.00)),  # nocked - pulled a hair back
                (0.36, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),
                (0.42, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),
            ],
            "hand": [
                (0.00, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),
                (0.14, (-24.0, 0.0, 10.0), (0.24, 0.14, -1.06)),  # carries the arrow up
                (0.26, (-6.0, 0.0, 2.0), (0.06, 0.02, -0.10)),
                (0.31, (0.0, 0.0, 0.0), (0.02, -0.07, 0.04)),  # pinches it to the string
                (0.42, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),
            ],
        },
    },
}

# ---------------------------------------------------------------- preview

PREVIEW_GUN_SIZE = Vector((0.25, 2.8, 0.5))
PREVIEW_MAG_SIZE = Vector((0.2, 0.55, 0.32))
PREVIEW_MAG_AT = Vector((0.0, 0.4, -0.45))
PREVIEW_ACTION_SIZE = Vector((0.14, 0.4, 0.18))
PREVIEW_ACTION_AT = Vector((0.12, -0.2, 0.18))
PREVIEW_HAND_SIZE = Vector((1.0, 0.3, 1.0))
PREVIEW_HAND_PARK = Vector((-0.4, -0.6, -3.2))
PREVIEW_GUN_AT = Vector((1.3, 2.4, -1.3))  # camera space-ish, blender axes


def roblox_from_key(rot_deg, loc):
    return (
        Euler(tuple(math.radians(a) for a in rot_deg), "XYZ"),
        Vector((loc[0], loc[1], loc[2])),
    )


def clear_scene():
    bpy.ops.wm.read_factory_settings(use_empty=True)


def make_box(name, size, at):
    mesh = bpy.data.meshes.new(name)
    obj = bpy.data.objects.new(name, mesh)
    bpy.context.scene.collection.objects.link(obj)
    import bmesh as _bm

    bm = _bm.new()
    _bm.ops.create_cube(bm, size=1.0)
    for v in bm.verts:
        v.co.x *= size.x
        v.co.y *= size.y
        v.co.z *= size.z
    bm.to_mesh(mesh)
    bm.free()
    obj.location = at
    return obj


def sample_key_list(keys, t):
    """Bezier-free linear sample of (time, rot, loc) keys at t (preview only;
    the export path uses Blender's own bezier interpolation)."""
    if t <= keys[0][0]:
        return roblox_from_key(keys[0][1], keys[0][2])
    for i in range(len(keys) - 1):
        t0, r0, l0 = keys[i]
        t1, r1, l1 = keys[i + 1]
        if t0 <= t <= t1:
            u = (t - t0) / max(t1 - t0, 1e-6)
            rot = tuple(a + (b - a) * u for a, b in zip(r0, r1))
            loc = tuple(a + (b - a) * u for a, b in zip(l0, l1))
            return roblox_from_key(rot, loc)
    return roblox_from_key(keys[-1][1], keys[-1][2])


def render_stills(out_dir):
    os.makedirs(out_dir, exist_ok=True)
    for name, clip in CLIPS.items():
        clear_scene()
        scene = bpy.context.scene
        scene.render.engine = "BLENDER_WORKBENCH"
        scene.render.resolution_x = 640
        scene.render.resolution_y = 480
        cam = bpy.data.objects.new("Cam", bpy.data.cameras.new("Cam"))
        scene.collection.objects.link(cam)
        scene.camera = cam
        cam.location = Vector((0, -0.5, 0))
        cam.rotation_euler = Euler((math.radians(90), 0, 0), "XYZ")
        sun = bpy.data.objects.new("Sun", bpy.data.lights.new("Sun", "SUN"))
        scene.collection.objects.link(sun)
        sun.rotation_euler = Euler((math.radians(60), 0, math.radians(20)), "XYZ")

        gun = make_box("Gun", PREVIEW_GUN_SIZE, PREVIEW_GUN_AT)
        mag = make_box("Mag", PREVIEW_MAG_SIZE, PREVIEW_GUN_AT + PREVIEW_MAG_AT)
        act = make_box("Act", PREVIEW_ACTION_SIZE, PREVIEW_GUN_AT + PREVIEW_ACTION_AT)
        hand = make_box("Hand", PREVIEW_HAND_SIZE * 0.5, PREVIEW_GUN_AT + PREVIEW_HAND_PARK)
        homes = {
            "mag": mag.location.copy(),
            "action": act.location.copy(),
            "hand": PREVIEW_GUN_AT + Vector((0.0, 0.4, -0.7)),
        }
        duration = clip["DURATION"]
        for i in range(6):
            t = duration * i / 5.0
            tracks = clip["TRACKS"]
            if "weapon" in tracks:
                rot, loc = sample_key_list(tracks["weapon"], t)
                gun.rotation_euler = rot
                gun.location = PREVIEW_GUN_AT + loc
            for obj, key in ((mag, "mag"), (act, "action"), (hand, "hand")):
                if key not in tracks:
                    continue
                rot, loc = sample_key_list(tracks[key], t)
                obj.rotation_euler = rot
                base = homes[key] if key != "hand" else homes["hand"]
                park = Vector((0, 0, 0)) if key != "hand" else Vector((0, 0, 0))
                obj.location = base + loc + park
            scene.render.filepath = os.path.join(out_dir, f"{name}_{i}.png")
            bpy.ops.render.render(write_still=True)
        print(f"[gun_reload_anim] stills: {name} x6 -> {out_dir}")


# ---------------------------------------------------------------- export


def fcurves_of(obj):
    """Action F-curves, tolerant of the 4.4+ slotted-action layout (same
    helper as weapon_swing_anim.py)."""
    if not (obj.animation_data and obj.animation_data.action):
        return []
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


def bake_track(keys, duration):
    """Bezier-interp the keys with Blender fcurves (the swing pipeline's
    easing) and sample per frame to (x,y,z,qx,qy,qz,qw) camera-space tuples."""
    clear_scene()
    scene = bpy.context.scene
    obj = bpy.data.objects.new("Track", None)
    scene.collection.objects.link(obj)
    for t, rot_deg, loc in keys:
        frame = round(t * FPS)
        obj.rotation_euler = Euler(tuple(math.radians(a) for a in rot_deg), "XYZ")
        obj.location = Vector(loc)
        obj.keyframe_insert(data_path="rotation_euler", frame=frame)
        obj.keyframe_insert(data_path="location", frame=frame)
    for fc in fcurves_of(obj):
        for kp in fc.keyframe_points:
            kp.interpolation = "BEZIER"
            kp.handle_left_type = "AUTO_CLAMPED"
            kp.handle_right_type = "AUTO_CLAMPED"
        fc.update()
    last = round(duration * FPS)
    frames = []
    for f in range(last + 1):
        scene.frame_set(f)
        # blender (x right, y fwd, z up) -> roblox camera (x right, y up, -z fwd)
        p = obj.location
        q = obj.rotation_euler.to_quaternion()
        frames.append((p.x, p.z, -p.y, q.x, q.z, -q.y, q.w))
    return frames


def fmt(n):
    s = f"{n:.4f}"
    return "0.0000" if s == "-0.0000" else s


def write_luau(path):
    lines = [
        "--!nonstrict",
        "-- GunReloadAnim.luau",
        "-- GENERATED by assets/gun_reload_anim.py - do not hand-edit. Change the",
        "-- CLIPS table in that script and re-run it (see assets/README.md).",
        "--",
        "-- One multi-track reload clip per WeaponPack gun variant (+ Generic, the",
        "-- fallback). Tracks: weapon (whole viewmodel about the right elbow - the",
        "-- swing contract), mag / action (that part, local about its own home),",
        "-- hand (the parked left arm, local about its rest). Frames are",
        "-- { x, y, z, qx, qy, qz, qw } camera-space CFrames at FPS.",
        "-- WeaponViewmodelController time-scales DURATION to the row's",
        "-- ranged.reloadTime (or plays it inside the cooldown for reloadTime-0",
        "-- guns) - see reloadAnim there.",
        "",
        "local GunReloadAnim = {}",
        "",
        f"GunReloadAnim.FPS = {FPS}",
        "",
        "GunReloadAnim.CLIPS = {",
    ]
    for name, clip in CLIPS.items():
        duration = clip["DURATION"]
        lines.append(f"\t{name} = {{")
        lines.append(f"\t\tDURATION = {duration},")
        lines.append("\t\tTRACKS = {")
        for track_name, keys in clip["TRACKS"].items():
            frames = bake_track(keys, duration)
            lines.append(f"\t\t\t{track_name} = {{")
            for f in frames:
                lines.append("\t\t\t\t{ " + ", ".join(fmt(v) for v in f) + " },")
            lines.append("\t\t\t},")
            print(f"[gun_reload_anim] {name}.{track_name}: {len(frames)} frames")
        lines.append("\t\t},")
        lines.append("\t},")
    lines.append("}")
    lines.append("")
    lines.append("return GunReloadAnim")
    lines.append("")
    with open(path, "w") as handle:
        handle.write("\n".join(lines))
    print(f"[gun_reload_anim] exported {path}")


def main():
    args = sys.argv[sys.argv.index("--") + 1 :]
    out = os.path.abspath(args[0])
    write_luau(out)
    if len(args) >= 3 and args[1] == "stills":
        render_stills(os.path.abspath(args[2]))


main()
