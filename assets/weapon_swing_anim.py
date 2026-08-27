# weapon_swing_anim.py
# Authors the first-person melee weapon swings in Blender and exports them
# as a Luau data module the weapon viewmodel plays back. Same pipeline as the
# cast (rod_cast_anim.py) and the punches (fist_punch_anim.py) - run headless:
#
#   blender --background --python-exit-code 1 --python assets/weapon_swing_anim.py -- src/Shared/Data/WeaponSwingAnim.luau
#
# What it produces:
#   - src/Shared/Data/WeaponSwingAnim.luau   one clip per entry in CLIPS - as
#                                            of the 2026-08-27 revamp that is
#                                            one BESPOKE clip per melee weapon
#                                            row, sampled per frame
#   - assets/weapon_swing.blend              a preview of the LAST clip in
#                                            CLIPS: a stand-in weapon + block
#                                            arm at the in-game pose, camera
#                                            at the player's eye.
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
    # ---------------------------------------------------------------- 2026-08-27
    # THE MELEE REVAMP. The previous pass shipped eight shared "family" classes
    # and the user's verdict was that every weapon read the same - "one
    # dimensional". So: one BESPOKE clip per melee row, and the family the row
    # belongs to decides the AXIS the swing lives on, not the whole animation.
    #
    #   daggers / short blades  ->  HORIZONTAL, left to right, plus a backhand
    #   swords / sabers /
    #     cutlasses / machetes  ->  VERTICAL, up to down
    #   spears / lances /
    #     harpoons / spikes     ->  FORWARD, a driven thrust
    #   axes / hammers /
    #     mauls / clubs         ->  heavy OVERHEAD, up to down, with weight
    #   gauntlets               ->  straight punches
    #
    # On top of the axis every clip carries the weapon's own character (the
    # machete saws, the boarding axe hooks, the lance sets its shoulder, the
    # trenchspike's barbs shudder on the pull-out), and every clip is built in
    # four phases with DELIBERATELY uneven timing - anticipation (slow),
    # contact (a snap, 1-2 frames), follow-through (an overshoot past contact),
    # settle (an eased drift home, usually cut short by the next swing). A
    # constant-speed arc is the bug being fixed here; there are none below.
    #
    # Reading the channels (see the KEYS comment above):
    #   X  pitch about the camera's right axis. POSITIVE lifts the weapon back
    #      over the shoulder; NEGATIVE drives it down and forward. This is the
    #      vertical channel - the chops and cuts live here.
    #   Y  roll about the camera's forward axis. POSITIVE tips an upright
    #      weapon toward screen RIGHT. Mostly used to turn the edge into the
    #      cut and to sell wrist work.
    #   Z  yaw about the camera's up axis. POSITIVE carries the weapon LEFT,
    #      across the body toward and past screen centre; NEGATIVE takes it out
    #      to the right. This is the horizontal channel - the slashes live here.
    #
    # Durations are authored real (playback is NOT rescaled) at about 1.6x the
    # row's cooldown, so a full-rate attacker's next swing interrupts during
    # the settle - after the swing has fully read - and never during the cut.
    # DURATION * COMBO_WINDOW (0.45, WeaponViewmodelController) is under every
    # row's cooldown, so no input is ever swallowed.

    # ================================================================ DAGGERS
    # Horizontal, left to right. Wind up ACROSS the body to the left (Z+), whip
    # right through the centre (Z-), and let the recovery be the return
    # backhand rather than a dead drift home.

    # Scaleblade (cd 0.20) - the fastest thing in the game. All wrist, no
    # shoulder: a flick across the body and a snap back. Two cuts on screen in
    # a third of a second.
    "scale_flick": {
        "HIT_TIME": 0.10,
        "KEYS": [
            (0.000, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),  # idle
            (0.050, (-32.0, -20.0, 46.0), (-0.22, -0.14, 0.02)),  # cocked across the body, blade levelled
            (0.100, (-52.0, 18.0, -40.0), (0.34, 0.34, -0.06)),  # SNAP left-to-right through the centre (HIT_TIME)
            (0.140, (-56.0, 26.0, -56.0), (0.44, 0.24, -0.10)),  # carried off the right edge
            (0.210, (-30.0, -10.0, 26.0), (-0.14, 0.16, 0.06)),  # the return backhand cuts back
            (0.270, (-8.0, 0.0, 6.0), (-0.02, 0.04, 0.02)),  # settling
            (0.3333, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),  # idle
        ],
    },

    # Krakenfang (cd 0.42) - a curved fang, so it does not cut, it BITES and
    # tears: horizontal bite, a hook where it catches, then wrenched back out
    # with a shudder. The endgame blade; the recovery is the show.
    "kraken_rip": {
        "HIT_TIME": 0.20,
        "KEYS": [
            (0.000, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),  # idle
            (0.060, (-7.0, -15.0, 26.0), (-0.14, -0.09, 0.07)),  # the coil starts SLOW - half wound
            (0.133, (-16.0, -34.0, 58.0), (-0.32, -0.20, 0.16)),  # fully coiled across the body, fang raised
            (0.200, (-54.0, 32.0, -42.0), (0.36, 0.52, -0.12)),  # BITE left-to-right, driven in (HIT_TIME)
            (0.267, (-38.0, 42.0, -54.0), (0.46, 0.10, -0.02)),  # the fang catches - dragged back, still right
            (0.333, (6.0, 12.0, -22.0), (0.16, -0.24, 0.16)),  # torn out and up
            (0.450, (-6.0, -6.0, 8.0), (-0.06, 0.06, -0.04)),  # counter-shudder the other way
            (0.540, (-2.0, -2.0, 3.0), (-0.02, 0.02, -0.01)),  # settling
            (0.6333, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),  # idle
        ],
    },

    # ================================================================ BLADES
    # Vertical, up to down. Raise the blade back over the shoulder (X+), fall
    # through the centre of the screen (X far -), overshoot, recover.

    # Drowncleaver (cd 0.22) - a broad cursed cleaver swung fast. Short raise,
    # brutal drop, almost no ceremony: the speed is the character.
    "drown_cleave": {
        "HIT_TIME": 0.12,
        "KEYS": [
            (0.000, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),  # idle
            (0.060, (44.0, -14.0, -12.0), (0.10, -0.18, 0.34)),  # snatched up over the shoulder
            (0.120, (-78.0, 10.0, 26.0), (-0.18, 0.42, -0.34)),  # DOWN through the centre (HIT_TIME)
            (0.160, (-88.0, 14.0, 32.0), (-0.22, 0.32, -0.44)),  # overshoot low
            (0.250, (-22.0, 4.0, 8.0), (-0.06, 0.10, -0.12)),  # hauled most of the way back fast
            (0.3667, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),  # idle
        ],
    },

    # Heartrender (cd 0.28) - it drinks what it kills, so the cut does not
    # bounce off: it PRESSES deeper after contact and is dragged back out.
    "heartcut": {
        "HIT_TIME": 0.14,
        "KEYS": [
            (0.000, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),  # idle
            (0.070, (50.0, -18.0, -14.0), (0.12, -0.20, 0.38)),  # raised high, blade rolled back
            (0.140, (-80.0, 12.0, 24.0), (-0.16, 0.46, -0.36)),  # the cut lands (HIT_TIME)
            (0.190, (-92.0, 16.0, 30.0), (-0.20, 0.54, -0.48)),  # PRESSED deeper, forward and low
            (0.250, (-84.0, 22.0, 34.0), (-0.26, 0.16, -0.42)),  # dragged back out of the wound
            (0.330, (-26.0, 8.0, 12.0), (-0.08, 0.02, -0.14)),  # lifted
            (0.4333, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),  # idle
        ],
    },

    # Rustfang Machete (cd 0.24) - the ragged rust-eaten edge does not cut
    # clean, it SAWS: after the chop lands the blade judders back and then
    # forward before tearing free. Two alternating strokes on consecutive
    # frames, because the ENTIRE motif - raise, chop, saw, tear free - has to
    # finish inside the 0.24 cooldown (torn free at 0.233) so a spam-clicking
    # player sees the character every swing and only ever interrupts the
    # settle. A third stroke would not fit without pushing the tear past 0.24.
    "rust_saw": {
        "HIT_TIME": 0.133,
        "KEYS": [
            (0.000, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),  # idle
            (0.067, (42.0, -16.0, -14.0), (0.12, -0.16, 0.32)),  # raised (frame 2)
            (0.133, (-74.0, 12.0, 22.0), (-0.14, 0.44, -0.32)),  # chopped down through the centre (HIT_TIME, frame 4)
            (0.167, (-64.0, 20.0, 30.0), (-0.22, 0.20, -0.28)),  # saw 1 - dragged back (frame 5)
            (0.200, (-82.0, 6.0, 18.0), (-0.06, 0.46, -0.40)),  # saw 2 - shoved forward (frame 6)
            (0.233, (-30.0, 4.0, 10.0), (-0.06, 0.06, -0.12)),  # torn free (frame 7) - the whole motif inside the 0.24 cooldown
            (0.300, (-10.0, 1.0, 3.0), (-0.02, 0.02, -0.04)),  # settling (the only interruptible tail)
            (0.400, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),  # idle
        ],
    },

    # Voidglass Saber (cd 0.45) - trench glass, black past black. The blade
    # HANGS at the apex a beat longer than it should (it is heavier than
    # light), then falls rolling flat-to-edge, and drifts home slowly.
    "void_cut": {
        "HIT_TIME": 0.15,
        "KEYS": [
            (0.000, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),  # idle
            (0.070, (40.0, -34.0, -20.0), (0.16, -0.14, 0.32)),  # rising, blade rolled flat
            (0.120, (52.0, -40.0, -22.0), (0.18, -0.20, 0.46)),  # the apex float - the glass hangs
            (0.150, (-78.0, 26.0, 26.0), (-0.18, 0.46, -0.34)),  # rolls edge-down and FALLS (HIT_TIME)
            (0.200, (-90.0, 34.0, 40.0), (-0.34, 0.34, -0.46)),  # follow through low and left
            (0.290, (-30.0, 10.0, 14.0), (-0.10, 0.06, -0.14)),  # lifted, rolling upright
            (0.430, (-6.0, 2.0, 3.0), (-0.02, 0.01, -0.03)),  # a slow drift home
            (0.6333, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),  # idle
        ],
    },

    # Cutlass of the Fleet (cd 0.42) - every officer at once, so it shows off:
    # the WIND-UP is a full wrist flourish, the point looping over the top,
    # before the blade arrives high and cuts straight down. Recovers by
    # snapping out to the right, flat, the way a drill does.
    "fleet_flourish": {
        "HIT_TIME": 0.17,
        "KEYS": [
            (0.000, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),  # idle
            (0.050, (-26.0, 30.0, -22.0), (0.14, 0.06, -0.14)),  # the point drops right, the wrist starts the loop
            (0.100, (34.0, 54.0, -6.0), (0.06, 0.06, 0.28)),  # the loop carries over the top
            (0.135, (54.0, -16.0, -14.0), (0.12, -0.22, 0.44)),  # arrives cocked high, wrist unwound
            (0.170, (-80.0, 12.0, 24.0), (-0.16, 0.48, -0.36)),  # straight DOWN through the centre (HIT_TIME)
            (0.220, (-92.0, 18.0, 30.0), (-0.20, 0.36, -0.48)),  # follow through
            (0.300, (-24.0, -28.0, -18.0), (0.20, 0.08, -0.06)),  # snapped out right, flat - the officer's recover
            (0.430, (-6.0, -8.0, -5.0), (0.06, 0.02, -0.01)),  # settling
            (0.6333, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),  # idle
        ],
    },

    # Admiral's Saber (cd 0.42) - Wrack's own, and it fences. A small salute
    # (the point dips and rolls) before the blade goes up, one clean vertical
    # cut, and a crisp return to guard with a tiny bounce.
    "admiral_cut": {
        "HIT_TIME": 0.16,
        "KEYS": [
            (0.000, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),  # idle
            (0.060, (-18.0, 22.0, 10.0), (0.02, 0.08, -0.10)),  # the salute - point dips and rolls
            (0.110, (48.0, -24.0, -16.0), (0.14, -0.16, 0.40)),  # up into the cut, edge turned down
            (0.160, (-84.0, 14.0, 22.0), (-0.14, 0.48, -0.38)),  # the cut, dead vertical (HIT_TIME)
            (0.210, (-92.0, 20.0, 26.0), (-0.16, 0.38, -0.48)),  # follow through
            (0.290, (-14.0, -12.0, 6.0), (0.04, 0.06, 0.06)),  # snapped back to guard
            (0.400, (8.0, -4.0, -4.0), (0.02, -0.04, 0.06)),  # the guard's small bounce
            (0.600, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),  # idle
        ],
    },

    # Galecleaver (cd 0.45) - a broad blade with the wind behind it. Vertical
    # cleave, but the gale CARRIES the follow-through: instead of stopping low
    # the blade is dragged on around to the left and swept back up that side.
    "gale_cleave": {
        "HIT_TIME": 0.18,
        "KEYS": [
            (0.000, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),  # idle
            (0.080, (46.0, -20.0, -34.0), (0.26, -0.20, 0.36)),  # wound back and out right
            (0.130, (54.0, -24.0, -30.0), (0.24, -0.26, 0.46)),  # the hang while the wind gathers
            (0.180, (-76.0, 16.0, 20.0), (-0.14, 0.50, -0.34)),  # CLEAVES down through the centre (HIT_TIME)
            (0.240, (-84.0, 30.0, 54.0), (-0.46, 0.30, -0.44)),  # the gale carries it around to the low left
            (0.310, (-34.0, 20.0, 44.0), (-0.40, 0.06, -0.10)),  # swept up the left side
            (0.430, (-8.0, 6.0, 16.0), (-0.14, 0.02, 0.02)),  # crossing back
            (0.6667, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),  # idle
        ],
    },

    # Fenreaver (cd 0.27) - a root-bark GLAIVE, and a glaive reaps. The odd one
    # in the blade family: it starts LOW and out right, scythes up and across
    # through the centre, and finishes over the left shoulder. Rising diagonal,
    # not a chop - the polearm's own shape.
    "root_reap": {
        "HIT_TIME": 0.15,
        "KEYS": [
            (0.000, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),  # idle
            (0.060, (-34.0, 26.0, -34.0), (0.24, 0.06, -0.20)),  # dropped low and out right, butt raised
            (0.150, (-52.0, -22.0, 44.0), (-0.36, 0.44, -0.02)),  # REAPS up and across the centre (HIT_TIME)
            (0.200, (20.0, -34.0, 56.0), (-0.44, 0.36, 0.26)),  # carried up over the left shoulder
            (0.290, (6.0, -8.0, 20.0), (-0.14, 0.02, 0.12)),  # brought back down across
            (0.360, (-2.0, -2.0, 6.0), (-0.04, 0.01, 0.03)),  # settling
            (0.4333, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),  # idle
        ],
    },

    # ================================================================ THRUSTS
    # ---------------------------------------------------------------- 2026-08-27, second pass
    # "the spear should be like a jab forward. the spear should just be held
    # horizontally and jabbed forward." (user)
    #
    # The first pass built these as thrusts wrapped in choreography - big pitch
    # coils, twists, three-beat barb shudders - on top of a hold that carried
    # the spear UPRIGHT beside the eye. From that hold a thrust had to swing
    # the point down to level first, so the rotation channels carried as much
    # of the motion as the translation did and none of it read as a jab.
    #
    # Both halves are fixed. Weapons.luau now gives all four rows a `hold`
    # that carries the shaft NEAR-LEVEL (pitch ~10 deg), so pure forward
    # translation IS a jab straight down the shaft, and these clips are
    # rewritten as exactly that and nothing else:
    #
    #   1. a SHORT quick pull-back      ~0.18-0.25 studs of -y, 1-2 frames
    #   2. a hard straight JAB          1.05-1.30 studs of +y, 2 frames of
    #                                   transit (never a one-frame pop)
    #   3. a brief HOLD at extension    2-3 sampled frames, so contact reads
    #   4. a straight pull back to carry, then an eased settle
    #
    # Rotation is now DECORATION ONLY - it never exceeds 14 degrees on any
    # channel anywhere in a jab, against 30-54 in the clips these replace. The
    # character is in the TIMING, not the shape: the lance's dead shoulder-set
    # beat, the stormlance's crackle at extension, the trenchspike's one-frame
    # coil, the piercer's small twist at full depth. Everything else - the
    # coils, the arcs, the barb shudders - is gone on purpose.

    # Obsidian Piercer (cd 0.40) - glass on a haft. Straight jab; the only
    # flourish is a small TWIST held at full extension (that is how obsidian
    # punches through), then a fast clean withdraw.
    "glass_pierce": {
        "HIT_TIME": 0.1667,
        "KEYS": [
            (0.0000, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),  # idle - the horizontal carry
            (0.0667, (4.0, 0.0, -2.0), (0.02, -0.22, 0.02)),  # frame 2 - the short pull-back, that is all of it
            (0.1333, (-2.0, 0.0, 4.0), (-0.04, 0.55, -0.03)),  # frame 4 - the jab at speed, half way out
            (0.1667, (-4.0, 0.0, 7.0), (-0.08, 1.15, -0.05)),  # frame 5 - FULL EXTENSION (HIT_TIME)
            (0.2000, (-4.0, -14.0, 7.0), (-0.08, 1.18, -0.05)),  # frame 6 - held out, and the twist bites
            (0.2333, (-4.0, -12.0, 7.0), (-0.08, 1.14, -0.05)),  # frame 7 - still buried, twist holding
            (0.3000, (-1.0, -4.0, 3.0), (-0.03, 0.42, -0.02)),  # frame 9 - drawn straight back
            (0.3667, (3.0, 0.0, -1.0), (0.01, -0.08, 0.01)),  # frame 11 - back at the carry, a hair past
            (0.4333, (1.0, 0.0, 0.0), (0.00, -0.02, 0.00)),  # frame 13 - settling
            (0.5333, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),  # idle
        ],
    },

    # Rimefang Lance (cd 0.42) - the couched lance. The signature survives the
    # rewrite because it was always timing, not shape: the SET, a dead beat
    # where the haft locks into the shoulder and NOTHING moves, then the
    # longest jab in the game out of a standing start.
    "rime_lance": {
        "HIT_TIME": 0.2000,
        "KEYS": [
            (0.0000, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),  # idle - the horizontal carry
            (0.0667, (5.0, 0.0, -3.0), (0.03, -0.24, 0.03)),  # frame 2 - drawn back to the shoulder
            (0.1333, (5.0, 0.0, -3.0), (0.03, -0.25, 0.03)),  # frame 4 - the SET: two frames where nothing moves
            (0.1667, (0.0, 0.0, 3.0), (-0.03, 0.50, -0.02)),  # frame 5 - the jab breaks, half way out
            (0.2000, (-5.0, 0.0, 8.0), (-0.09, 1.30, -0.06)),  # frame 6 - FULL EXTENSION, the longest reach (HIT_TIME)
            (0.2333, (-5.0, 2.0, 8.0), (-0.09, 1.32, -0.06)),  # frame 7 - pinned there
            (0.2667, (-4.0, 0.0, 7.0), (-0.08, 1.28, -0.05)),  # frame 8 - still pinned
            (0.3333, (0.0, 0.0, 3.0), (-0.02, 0.46, -0.02)),  # frame 10 - hauled straight back
            (0.4000, (4.0, 0.0, -2.0), (0.02, -0.10, 0.02)),  # frame 12 - recovered to the carry
            (0.4667, (1.0, 0.0, -1.0), (0.01, -0.03, 0.01)),  # frame 14 - settling
            (0.5667, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),  # idle
        ],
    },

    # Trenchspike (cd 0.42) - "It has no tricks. It doesn't need one." The
    # snappiest of the four and the one that most needed the rewrite: the
    # three-beat barb shudder was the single busiest thing on screen. Now the
    # coil is ONE frame, the stab lands on frame 4, and the pull-out is a
    # straight line. The tricklessness is the character.
    "trench_stab": {
        "HIT_TIME": 0.1333,
        "KEYS": [
            (0.0000, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),  # idle - the horizontal carry
            (0.0333, (4.0, 0.0, -2.0), (0.02, -0.18, 0.02)),  # frame 1 - the least pull-back that reads
            (0.1000, (-1.0, 0.0, 4.0), (-0.04, 0.60, -0.03)),  # frame 3 - already half way out
            (0.1333, (-5.0, 0.0, 8.0), (-0.09, 1.22, -0.06)),  # frame 4 - FULL EXTENSION (HIT_TIME)
            (0.1667, (-5.0, 0.0, 8.0), (-0.09, 1.25, -0.06)),  # frame 5 - buried to the hand
            (0.2000, (-4.0, 0.0, 7.0), (-0.08, 1.20, -0.05)),  # frame 6 - still buried
            (0.2667, (0.0, 0.0, 3.0), (-0.02, 0.42, -0.02)),  # frame 8 - pulled straight back out
            (0.3333, (3.0, 0.0, -1.0), (0.01, -0.06, 0.01)),  # frame 10 - back at the carry
            (0.4000, (1.0, 0.0, 0.0), (0.00, -0.02, 0.00)),  # frame 12 - settling
            (0.5000, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),  # idle
        ],
    },

    # Stormlance (cd 0.45) - a live current down the haft. The crackle stays,
    # but it MOVED: it used to jitter the wind-up (which read as the player
    # fumbling the weapon), and now it is a tiny roll-channel buzz on the
    # three frames the lance is held in the wound - the discharge going off
    # where the point is, which is where the story is.
    "storm_lance": {
        "HIT_TIME": 0.1667,
        "KEYS": [
            (0.0000, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),  # idle - the horizontal carry
            (0.0667, (5.0, 0.0, -3.0), (0.03, -0.25, 0.03)),  # frame 2 - the pull-back, charge gathering
            (0.1333, (0.0, 0.0, 4.0), (-0.04, 0.58, -0.03)),  # frame 4 - the jab at speed, half way out
            (0.1667, (-5.0, 0.0, 8.0), (-0.09, 1.25, -0.06)),  # frame 5 - FULL EXTENSION (HIT_TIME)
            (0.2000, (-5.0, 6.0, 8.0), (-0.10, 1.30, -0.06)),  # frame 6 - crackle: the haft kicks one way
            (0.2333, (-4.0, -6.0, 7.0), (-0.08, 1.26, -0.05)),  # frame 7 - and back the other, still extended
            (0.2667, (-4.0, 3.0, 7.0), (-0.09, 1.22, -0.06)),  # frame 8 - the last flick of the discharge
            (0.3333, (2.0, 0.0, 2.0), (-0.02, 0.38, -0.01)),  # frame 10 - the arc shoves it back out
            (0.4000, (4.0, 0.0, -2.0), (0.02, -0.10, 0.02)),  # frame 12 - recovered to the carry
            (0.4667, (1.0, -2.0, -1.0), (0.01, -0.03, 0.01)),  # frame 14 - the buzz decaying
            (0.5667, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),  # idle
        ],
    },

    # ================================================================ HEAVIES
    # Overhead, up to down, with weight: a SLOW hoist, a hang at the apex so
    # the mass reads, a fall two to three times faster than the lift, a buried
    # beat where everything stops, and a long dragging recovery.

    # Driftwood Club (cd 0.45) - the first weapon anyone builds. Honest and
    # dumb: hoist, hang, club it down, heave it back up.
    "cudgel_bash": {
        "HIT_TIME": 0.20,
        "KEYS": [
            (0.000, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),  # idle
            (0.090, (48.0, -10.0, -18.0), (0.14, -0.22, 0.36)),  # hoisted back over the shoulder
            (0.150, (58.0, -12.0, -20.0), (0.16, -0.12, 0.46)),  # the apex - the wood settles back
            (0.200, (-80.0, 8.0, 18.0), (-0.12, 0.48, -0.38)),  # clubbed down and forward (HIT_TIME)
            (0.260, (-92.0, 10.0, 22.0), (-0.14, 0.38, -0.52)),  # buried low
            (0.360, (-34.0, 4.0, 10.0), (-0.06, 0.10, -0.22)),  # heaved back up
            (0.480, (-10.0, 1.0, 3.0), (-0.02, 0.03, -0.06)),  # settling
            (0.600, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),  # idle
        ],
    },

    # Shellcrusher (cd 0.55) - a slab of barnacle chitin, and it is genuinely
    # too heavy. The lift STAGGERS partway up (the weight nearly wins) before
    # it is hauled to the apex, and the impact BOUNCES off the ground.
    "shell_crush": {
        "HIT_TIME": 0.30,
        "KEYS": [
            (0.000, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),  # idle
            (0.080, (32.0, -8.0, -12.0), (0.12, -0.16, 0.26)),  # the first heave
            (0.140, (28.0, -10.0, -14.0), (0.14, -0.10, 0.22)),  # the stagger - the weight nearly wins
            (0.200, (58.0, -12.0, -20.0), (0.18, -0.14, 0.52)),  # hauled to the apex anyway
            (0.250, (-22.0, 0.0, 2.0), (0.00, 0.26, 0.02)),  # MID-FALL - the head crossing the screen, a real transit sample
            (0.300, (-84.0, 8.0, 16.0), (-0.12, 0.52, -0.44)),  # CRASH, on the frame-9 boundary (HIT_TIME)
            (0.360, (-96.0, 10.0, 20.0), (-0.14, 0.42, -0.58)),  # the chitin bites in
            (0.430, (-86.0, 8.0, 18.0), (-0.12, 0.36, -0.48)),  # a dead bounce off the ground
            (0.540, (-40.0, 4.0, 10.0), (-0.06, 0.14, -0.26)),  # dragged back up
            (0.660, (-12.0, 1.0, 3.0), (-0.02, 0.04, -0.07)),  # settling
            (0.800, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),  # idle
        ],
    },

    # Icepick Hatchet (cd 0.22) - half tool, half temper, and it likes a
    # rhythm. The only light weapon in this family: a wrist-flick lift, a
    # picking drop, and a REBOUND where the pick kicks back out ready for the
    # next beat.
    "ice_hew": {
        "HIT_TIME": 0.12,
        "KEYS": [
            (0.000, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),  # idle
            (0.055, (38.0, -12.0, -12.0), (0.10, -0.12, 0.26)),  # flicked up - wrist only
            (0.120, (-70.0, 10.0, 20.0), (-0.14, 0.40, -0.28)),  # picked down through the centre (HIT_TIME)
            (0.155, (-80.0, 12.0, 24.0), (-0.16, 0.32, -0.36)),  # short follow
            (0.210, (-30.0, 4.0, 10.0), (-0.06, 0.08, -0.10)),  # the rebound - it kicks back out
            (0.280, (-6.0, 0.0, 2.0), (-0.01, 0.02, -0.02)),  # settling on the beat
            (0.3667, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),  # idle
        ],
    },

    # Boarding Axe (cd 0.50) - the fleet's pattern, made for clearing a deck.
    # The bearded head HOOKS: after the chop bites, the axe is hauled straight
    # back toward the player (the hook) and then wrenched free sideways.
    "deck_hook": {
        "HIT_TIME": 0.24,
        "KEYS": [
            (0.000, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),  # idle
            (0.100, (48.0, -18.0, -22.0), (0.20, -0.22, 0.40)),  # cocked high and back, haft across
            (0.170, (58.0, -20.0, -24.0), (0.22, -0.14, 0.52)),  # the apex
            (0.240, (-82.0, 12.0, 20.0), (-0.14, 0.50, -0.40)),  # chopped down through the centre (HIT_TIME)
            (0.300, (-94.0, 14.0, 24.0), (-0.16, 0.42, -0.54)),  # the beard bites in
            (0.380, (-88.0, 26.0, 34.0), (-0.30, 0.02, -0.50)),  # the HOOK - hauled straight back, still low
            (0.470, (-44.0, -14.0, -20.0), (0.24, 0.06, -0.24)),  # wrenched free out to the right
            (0.590, (-12.0, -4.0, -6.0), (0.07, 0.03, -0.06)),  # settling
            (0.7333, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),  # idle
        ],
    },

    # Glacier Maul (cd 0.70) - the heaviest thing in the game and the clip
    # says so: nearly a third of a second just lifting it, a long apex hang,
    # a fall in 50ms, a buried beat where the whole screen stops, and then the
    # head DRAGS along the ground before it can be hauled up.
    "maul_crash": {
        "HIT_TIME": 0.4333,
        "KEYS": [
            (0.000, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),  # idle
            (0.120, (38.0, -8.0, -10.0), (0.12, -0.18, 0.30)),  # the hoist begins - shoulders under it
            (0.220, (62.0, -12.0, -16.0), (0.18, -0.14, 0.56)),  # up past vertical
            (0.300, (66.0, -14.0, -18.0), (0.20, -0.16, 0.64)),  # the apex hang, frame 9 - the tell
            # The fall is keyed on EVERY frame from the apex to contact. A
            # 158-degree drop left to two keys collapses into one 157 deg/frame
            # step and the maul teleports; keying frames 10-12 makes the
            # sampler show the head actually crossing the screen, and lets the
            # per-step speed be shaped by hand into an acceleration
            # (26/40/47/48 deg per frame) instead of a single pop.
            (0.3333, (40.0, -10.0, -13.0), (0.15, -0.04, 0.45)),  # frame 10 - it tips over the top
            (0.3667, (0.0, -5.0, -5.0), (0.08, 0.14, 0.17)),  # frame 11 - past horizontal, gathering
            (0.4000, (-46.0, 1.0, 4.0), (0.03, 0.35, -0.15)),  # frame 12 - the fall at speed, still accelerating
            (0.4333, (-92.0, 8.0, 14.0), (-0.10, 0.56, -0.48)),  # CRASH through the centre, frame 13 (HIT_TIME)
            (0.500, (-104.0, 10.0, 18.0), (-0.12, 0.46, -0.66)),  # buried - everything stops
            (0.600, (-100.0, 14.0, 26.0), (-0.22, 0.16, -0.64)),  # the head DRAGS back along the ground
            (0.7333, (-48.0, 8.0, 14.0), (-0.10, 0.06, -0.34)),  # hauled up off the ground
            (0.8667, (-14.0, 2.0, 4.0), (-0.03, 0.03, -0.10)),  # settling
            (1.0000, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),  # idle
        ],
    },

    # ================================================================ FISTS
    # Straight punches: rotation near zero so the fist tracks the eyeline, all
    # the read in the translation.

    # Magma Gauntlets (cd 0.22) - cock to the cheek, piston straight out,
    # knuckles turn over on impact, and the retract carries a MICRO-JAB - the
    # flurry twitch that says the heat is still building.
    #
    # Retuned 2026-08-27 alongside the spears: the row's new `hold` carries the
    # gauntlet FIST-FORWARD (pitch 8) instead of upright, so the punch no
    # longer needs 14 degrees of pitch to point the fist at the crosshair - it
    # is already there. Pitch content is roughly a third of what it was and
    # the punch is nearly pure forward translation, with the knuckle roll kept
    # (that one is real hand mechanics, not decoration) and the extension now
    # held across three sampled frames instead of popping on one.
    "magma_piston": {
        "HIT_TIME": 0.1000,
        "KEYS": [
            (0.0000, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),  # idle - the fist-forward carry
            (0.0333, (5.0, 0.0, -3.0), (0.03, -0.26, 0.03)),  # frame 1 - cocked to the cheek, one frame
            (0.0667, (0.0, 0.0, 3.0), (-0.03, 0.52, -0.02)),  # frame 2 - the arm at speed, half way out
            (0.1000, (-4.0, 0.0, 6.0), (-0.07, 1.05, -0.04)),  # frame 3 - FULL EXTENSION (HIT_TIME)
            (0.1333, (-4.0, -12.0, 6.0), (-0.07, 1.08, -0.04)),  # frame 4 - the knuckles turn over on impact
            (0.1667, (-3.0, -8.0, 5.0), (-0.06, 1.00, -0.04)),  # frame 5 - still out, rolling back
            (0.2000, (1.0, 0.0, 2.0), (-0.01, 0.30, 0.00)),  # frame 6 - retract
            (0.2333, (-2.0, 0.0, 3.0), (-0.03, 0.52, -0.02)),  # frame 7 - the micro-jab, the flurry twitch
            (0.2667, (2.0, 0.0, 0.0), (0.01, 0.02, 0.01)),  # frame 8 - back at the guard
            (0.3333, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),  # idle
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
