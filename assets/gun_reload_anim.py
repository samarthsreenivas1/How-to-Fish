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
#     mag and action are DISPLACEMENTS FROM THE GUN, not replacements for
#     riding it: the engine composes (whatever the arm is doing) with the
#     track, so an all-identity mag track leaves the magazine bolted in the
#     well through recoil, swings and the `weapon` track. Author only the
#     part's own travel here; never re-key the gun's motion into it.
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
#   - The hand starts PARKED (the engine holds it off-screen the WHOLE time,
#     reload included - the track is added to the park, not swapped for it);
#     key it up into frame early and back down by the end.
#   - No track may start away from identity. Every track is identity between
#     clips, so a non-identity first key teleports its part on frame one -
#     that is what put the bow's arrow off-frame the instant a nock began.
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
                # Six chambers, six 60-deg indexes: the feed roll closes a
                # WHOLE turn by the time the crane swings shut, so the shut
                # position is identity and nothing turns after the lock. See
                # the same note on ThunderheadCannon.action.
                (0.00, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),
                (0.14, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),
                (0.24, (0.0, 42.0, 0.0), (-0.16, 0.00, -0.04)),  # swings out of the frame-left
                (0.42, (0.0, 46.0, 0.0), (-0.18, 0.00, -0.05)),  # tips with the eject
                (0.60, (0.0, 44.0, -60.0), (-0.17, 0.00, -0.04)),  # slow roll while feeding...
                (1.30, (0.0, 44.0, -300.0), (-0.17, 0.00, -0.04)),  # ...round after round
                (1.50, (0.0, 40.0, -360.0), (-0.15, 0.00, -0.03)),  # the sixth closes the turn
                (1.60, (0.0, 0.0, -360.0), (0.00, 0.00, 0.00)),  # snapped shut - already home
                (1.80, (0.0, 0.0, -360.0), (0.00, 0.00, 0.00)),  # dead still to the last frame
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
                (0.20, (-4.0, 6.0, -8.0), (0.05, -0.04, -0.05)),  # bow tips to meet the arrow
                (0.32, (2.0, -2.0, 3.0), (-0.02, 0.03, 0.02)),  # settle-draw tension
                (0.42, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),
            ],
            "mag": [  # the arrow
                # It has to LEAVE before a fresh one comes up: the clip starts
                # with the arrow still on the string (the engine holds every
                # track at identity between clips, so starting this one
                # off-frame popped the arrow out of the bow on frame one).
                (0.00, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),  # still nocked, as the shot leaves
                (0.05, (0.0, 0.0, 0.0), (0.06, 1.90, -0.10)),  # streaks away down the shaft line
                (0.11, (-24.0, 0.0, 10.0), (0.28, 0.24, -2.10)),  # the next one, down at the quiver
                (0.20, (-24.0, 0.0, 10.0), (0.22, 0.16, -1.10)),  # swept up from the quiver line
                (0.28, (-6.0, 0.0, 2.0), (0.04, 0.04, -0.14)),  # laid to the string
                (0.33, (0.0, 0.0, 0.0), (0.00, -0.05, 0.00)),  # nocked - pulled a hair back
                (0.38, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),
                (0.42, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),
            ],
            "hand": [
                (0.00, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),
                (0.11, (-24.0, 0.0, 10.0), (0.30, 0.22, -2.06)),  # dives to the quiver
                (0.20, (-24.0, 0.0, 10.0), (0.24, 0.14, -1.06)),  # carries the arrow up
                (0.28, (-6.0, 0.0, 2.0), (0.06, 0.02, -0.10)),
                (0.33, (0.0, 0.0, 0.0), (0.02, -0.07, 0.04)),  # pinches it to the string
                (0.42, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),
            ],
        },
    },

    # Heavy auto (1.2s): the carbine's swap at LMG weight - wider, slower arcs,
    # a two-handed haul on the drum, and the gun visibly SAGS when the fresh
    # mag's mass settles into the well before the bolt handle gets hauled back.
    "VulkanRepeater": {
        "DURATION": 1.2,
        "TRACKS": {
            "weapon": [
                (0.00, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),
                (0.18, (-10.0, 16.0, -26.0), (0.20, -0.14, -0.20)),  # heaves over to present the well
                (0.72, (-11.0, 16.0, -26.0), (0.20, -0.14, -0.22)),  # held through the long swap
                (0.86, (-24.0, 15.0, -28.0), (0.20, -0.10, -0.46)),  # SAG - the fresh mag's weight lands
                (0.98, (-6.0, 6.0, -10.0), (0.06, -0.05, -0.08)),  # muscled back up
                (1.08, (4.0, -3.0, 4.0), (-0.03, 0.03, 0.05)),  # overshoot past level
                (1.20, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),
            ],
            "mag": [
                (0.00, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),
                (0.20, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),  # hand gets a full grip first
                (0.34, (14.0, 0.0, 0.0), (0.22, 0.10, -0.90)),  # rocked free, heavy, swinging wide
                (0.52, (34.0, 0.0, 0.0), (0.52, 0.30, -3.10)),  # hauled down and OUT with both the hand
                (0.66, (-20.0, 0.0, 0.0), (0.44, 0.34, -2.85)),  # the fresh drum comes up the same path
                (0.80, (-9.0, 0.0, 0.0), (0.06, 0.07, -0.46)),  # swung in under the well, nose first
                (0.86, (0.0, 0.0, 0.0), (0.00, 0.00, 0.14)),  # seated on a heavy shove past home
                (0.92, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),
                (1.20, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),
            ],
            "hand": [
                (0.00, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),
                (0.20, (0.0, 0.0, 0.0), (-0.03, 0.03, 0.05)),  # closes on the drum
                (0.34, (14.0, 0.0, 0.0), (0.20, 0.12, -0.86)),  # same path as the mag...
                (0.52, (34.0, 0.0, 0.0), (0.50, 0.32, -3.06)),  # ...all the way down and out
                (0.66, (-20.0, 0.0, 0.0), (0.42, 0.36, -2.81)),  # ...and back with the fresh one
                (0.80, (-9.0, 0.0, 0.0), (0.04, 0.09, -0.42)),
                (0.86, (0.0, 0.0, 0.0), (-0.02, 0.03, 0.18)),  # the seating shove
                (0.96, (0.0, -16.0, 0.0), (0.32, -0.20, 0.30)),  # up to the bolt handle
                (1.06, (0.0, -16.0, 0.0), (0.32, -0.58, 0.30)),  # hauls it all the way back
                (1.20, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),
            ],
            "action": [
                (0.00, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),
                (0.96, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),
                (1.06, (0.0, 0.0, 0.0), (0.00, -0.34, 0.00)),  # bolt handle to the rear
                (1.12, (0.0, 0.0, 0.0), (0.00, 0.05, 0.00)),  # let fly, slams past home
                (1.20, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),
            ],
        },
    },

    # SMG (1.9s): rip the stick out, then the show-off beat - the hand FLIPS the
    # fresh mag over for a glance while the gun rolls to watch, rocks it in nose
    # first, and slaps the charging handle on the way back to level.
    "RiptideSmg": {
        "DURATION": 1.9,
        "TRACKS": {
            "weapon": [
                (0.00, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),
                (0.14, (-5.0, 16.0, -22.0), (0.14, -0.12, -0.10)),  # snapped over, quick
                (0.55, (-3.0, 20.0, -26.0), (0.16, -0.10, -0.06)),  # rolls further to watch the flip
                (1.15, (-4.0, 18.0, -24.0), (0.15, -0.11, -0.08)),  # back to the feeding angle
                (1.55, (-2.0, 5.0, -7.0), (0.05, -0.04, -0.04)),  # levelling for the handle slap
                (1.68, (2.0, -3.0, 4.0), (-0.02, 0.03, 0.03)),  # slap overshoot
                (1.90, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),
            ],
            "mag": [
                (0.00, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),
                (0.12, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),  # hand arrives
                (0.22, (12.0, 0.0, 0.0), (0.02, 0.05, -0.50)),  # rocked free
                (0.36, (26.0, 0.0, 0.0), (0.10, 0.18, -2.70)),  # ripped down out of frame
                (0.55, (-40.0, 0.0, 30.0), (0.18, 0.30, -1.50)),  # fresh stick brought up, tilted
                (0.75, (-40.0, 0.0, 210.0), (0.20, 0.32, -1.45)),  # THE FLIP - spun in the fingers
                (0.95, (-24.0, 0.0, 360.0), (0.14, 0.30, -1.60)),  # caught the right way round
                (1.15, (-14.0, 0.0, 360.0), (0.04, 0.08, -0.38)),  # brought to the well
                (1.28, (-8.0, 0.0, 360.0), (0.01, 0.03, -0.12)),  # front lip hooked in
                (1.36, (0.0, 0.0, 360.0), (0.00, 0.00, 0.07)),  # rocked back and shoved home
                (1.42, (0.0, 0.0, 360.0), (0.00, 0.00, 0.00)),
                (1.90, (0.0, 0.0, 360.0), (0.00, 0.00, 0.00)),  # a whole turn = identity
            ],
            "hand": [
                (0.00, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),
                (0.12, (0.0, 0.0, 0.0), (-0.02, 0.02, 0.04)),  # grabs the stick
                (0.22, (12.0, 0.0, 0.0), (0.00, 0.07, -0.46)),  # mirrors the mag from here...
                (0.36, (26.0, 0.0, 0.0), (0.08, 0.20, -2.66)),
                # The MAG makes the turn, not the arm: the hand keeps the
                # matched translation but only rocks (a wrist, not a
                # windmill), opening through the flip and closing on the
                # stick again once it comes round.
                (0.55, (-40.0, 0.0, 30.0), (0.16, 0.32, -1.46)),  # tilted with it as it comes up
                (0.75, (-30.0, 0.0, 10.0), (0.18, 0.34, -1.41)),  # opens - the mag spins in the fingers
                (0.95, (-24.0, 0.0, -20.0), (0.12, 0.32, -1.56)),  # closes again, right way round
                (1.15, (-14.0, 0.0, 0.0), (0.02, 0.10, -0.34)),
                (1.28, (-8.0, 0.0, 0.0), (-0.01, 0.05, -0.08)),
                (1.36, (0.0, 0.0, 0.0), (-0.02, 0.02, 0.11)),  # the rock-in shove
                (1.50, (0.0, -24.0, 0.0), (0.30, -0.18, 0.34)),  # over the top to the handle
                (1.58, (0.0, -24.0, 0.0), (0.30, -0.60, 0.34)),  # slaps it back
                (1.66, (0.0, -10.0, 0.0), (0.26, -0.10, 0.30)),  # lets go
                (1.90, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),
            ],
            "action": [
                (0.00, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),
                (1.50, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),
                (1.58, (0.0, 0.0, 0.0), (0.00, -0.32, 0.00)),  # handle slapped to the rear
                (1.63, (0.0, 0.0, 0.0), (0.00, 0.05, 0.00)),  # flies home past the stop
                (1.68, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),
                (1.90, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),
            ],
        },
    },

    # AR (2.0s): thumb the release and let the mag FALL FREE on its own gravity
    # beat - the hand is already gone to the pouch and never touches it. Fresh
    # one seated, then the heel of the palm smacks the bolt release and the
    # action snaps forward off the hold-open.
    "CycloneRifle": {
        "DURATION": 2.0,
        "TRACKS": {
            "weapon": [
                (0.00, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),
                (0.16, (-4.0, 10.0, -14.0), (0.10, -0.10, -0.08)),  # slight cant, well cleared
                (0.30, (-6.0, 12.0, -16.0), (0.11, -0.10, -0.10)),
                (1.10, (-6.0, 12.0, -16.0), (0.11, -0.10, -0.10)),
                (1.30, (-8.0, 12.0, -18.0), (0.11, -0.09, -0.14)),  # dips as the mag seats
                (1.55, (-3.0, 6.0, -8.0), (0.05, -0.05, -0.06)),
                (1.68, (3.0, -3.0, 4.0), (-0.02, 0.03, 0.03)),  # the bolt-release smack kicks it
                (1.80, (-1.0, 1.0, -1.0), (0.01, -0.01, -0.01)),
                (2.00, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),
            ],
            "mag": [
                (0.00, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),
                (0.14, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),  # thumb hits the release
                (0.22, (4.0, 0.0, 0.0), (0.00, 0.02, -0.35)),  # let go - starts to fall
                (0.34, (10.0, 0.0, 0.0), (0.01, 0.06, -1.10)),  # accelerating, nothing holding it
                (0.46, (18.0, 0.0, 0.0), (0.03, 0.10, -2.80)),  # gone
                (0.80, (-30.0, 0.0, 0.0), (0.20, 0.34, -2.90)),  # the hand finds a fresh one down there
                (1.02, (-20.0, 0.0, 0.0), (0.10, 0.24, -1.40)),  # riding the hand up
                (1.20, (-8.0, 0.0, 0.0), (0.02, 0.06, -0.30)),  # at the well
                (1.30, (0.0, 0.0, 0.0), (0.00, 0.00, 0.08)),  # seated with a shove past home
                (1.38, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),
                (2.00, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),
            ],
            "hand": [
                (0.00, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),
                (0.14, (0.0, 0.0, 0.0), (-0.06, 0.04, 0.06)),  # only long enough to hit the release
                (0.24, (-10.0, 0.0, 0.0), (-0.20, 0.10, -0.90)),  # already diving for the pouch
                (0.50, (-34.0, 0.0, 0.0), (-0.26, 0.20, -2.95)),  # at the pouch while the mag still falls
                (0.72, (-32.0, 0.0, 0.0), (0.06, 0.30, -2.95)),  # takes hold of the fresh one
                (0.80, (-30.0, 0.0, 0.0), (0.18, 0.36, -2.86)),  # mirrors the mag from here up
                (1.02, (-20.0, 0.0, 0.0), (0.08, 0.26, -1.36)),
                (1.20, (-8.0, 0.0, 0.0), (0.00, 0.08, -0.26)),
                (1.30, (0.0, 0.0, 0.0), (-0.02, 0.02, 0.12)),  # shoves it home
                (1.44, (0.0, -18.0, 0.0), (0.34, -0.16, 0.42)),  # palm up over the bolt release
                (1.56, (0.0, -18.0, 0.0), (0.30, -0.06, 0.30)),  # SMACK
                (1.66, (0.0, -6.0, 0.0), (0.20, 0.00, 0.24)),  # falls away
                (2.00, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),
            ],
            "action": [
                (0.00, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),
                (0.08, (0.0, 0.0, 0.0), (0.00, -0.30, 0.00)),  # shown locked back on empty
                (1.50, (0.0, 0.0, 0.0), (0.00, -0.30, 0.00)),  # held open the whole swap
                (1.56, (0.0, 0.0, 0.0), (0.00, 0.06, 0.00)),  # released - snaps forward past home
                (1.62, (0.0, 0.0, 0.0), (0.00, -0.02, 0.00)),  # rebound
                (2.00, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),
            ],
        },
    },

    # Lever gun with an underbarrel tube (2.0s): NOTHING comes out. The gun
    # rolls receiver-up and the hand thumbs three shells into the loading gate -
    # three identical pulses of the same path - then works the lever once.
    "PhantomRepeater": {
        "DURATION": 2.0,
        "TRACKS": {
            "weapon": [
                (0.00, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),
                (0.18, (6.0, -14.0, 22.0), (-0.10, -0.08, 0.06)),  # rolled left, gate presented
                (1.40, (5.0, -13.0, 21.0), (-0.09, -0.08, 0.06)),  # held there for all three shells
                (1.55, (14.0, -10.0, 18.0), (-0.08, -0.06, 0.10)),  # muzzle rises on the lever throw
                (1.72, (-6.0, -4.0, 6.0), (0.03, -0.02, -0.03)),  # snaps shut, muzzle drops
                (1.84, (3.0, -1.0, 2.0), (-0.01, 0.01, 0.01)),
                (2.00, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),
            ],
            "mag": [  # one shell, three times over
                (0.00, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),
                (0.36, (26.0, 0.0, 0.0), (0.30, -0.14, -2.70)),  # shell 1 off the belt
                (0.52, (-24.0, 0.0, 0.0), (0.16, -0.08, -0.44)),  # up under the barrel to the gate
                (0.62, (0.0, 0.0, 0.0), (0.02, 0.20, -0.08)),  # thumbed FORWARD into the tube
                (0.68, (0.0, 0.0, 0.0), (0.00, 0.02, 0.00)),  # gate springs shut behind it
                (0.72, (26.0, 0.0, 0.0), (0.30, -0.14, -2.70)),  # shell 2 - same path again
                (0.88, (-24.0, 0.0, 0.0), (0.16, -0.08, -0.44)),
                (0.98, (0.0, 0.0, 0.0), (0.02, 0.20, -0.08)),
                (1.04, (0.0, 0.0, 0.0), (0.00, 0.02, 0.00)),
                (1.06, (26.0, 0.0, 0.0), (0.30, -0.14, -2.70)),  # shell 3
                (1.22, (-24.0, 0.0, 0.0), (0.16, -0.08, -0.44)),
                (1.32, (0.0, 0.0, 0.0), (0.02, 0.20, -0.08)),
                (1.38, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),
                (2.00, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),
            ],
            "hand": [
                (0.00, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),
                (0.20, (0.0, 0.0, 0.0), (0.06, -0.04, -0.20)),  # rises off the park to the gate
                (0.36, (26.0, 0.0, 0.0), (0.32, -0.16, -2.66)),  # dips to the belt with the shell
                (0.52, (-24.0, 0.0, 0.0), (0.18, -0.10, -0.40)),
                (0.62, (0.0, 0.0, 0.0), (0.04, 0.22, -0.04)),  # thumb drives it in
                (0.68, (0.0, 0.0, 0.0), (0.02, 0.04, 0.02)),
                (0.72, (26.0, 0.0, 0.0), (0.32, -0.16, -2.66)),  # pulse two
                (0.88, (-24.0, 0.0, 0.0), (0.18, -0.10, -0.40)),
                (0.98, (0.0, 0.0, 0.0), (0.04, 0.22, -0.04)),
                (1.04, (0.0, 0.0, 0.0), (0.02, 0.04, 0.02)),
                (1.06, (26.0, 0.0, 0.0), (0.32, -0.16, -2.66)),  # pulse three
                (1.22, (-24.0, 0.0, 0.0), (0.18, -0.10, -0.40)),
                (1.32, (0.0, 0.0, 0.0), (0.04, 0.22, -0.04)),
                (1.38, (0.0, 0.0, 0.0), (0.02, 0.04, 0.02)),
                (1.42, (0.0, 0.0, 0.0), (0.06, 0.30, 0.10)),  # forward onto the forend to brace
                (1.60, (10.0, 0.0, 0.0), (0.06, 0.30, 0.06)),  # rides the lever cycle
                (1.75, (0.0, 0.0, 0.0), (0.05, 0.26, 0.08)),
                (2.00, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),
            ],
            "action": [  # the lever ring
                (0.00, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),
                (1.45, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),
                (1.58, (-70.0, 0.0, 0.0), (0.00, 0.06, -0.20)),  # thrown open, swung down and forward
                (1.70, (8.0, 0.0, 0.0), (0.00, -0.02, 0.03)),  # slammed back past shut
                (1.78, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),
                (2.00, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),
            ],
        },
    },

    # Scoped marksman (2.0s): the anti-carbine. Everything eased - the box mag
    # is drawn straight down, set aside LOW rather than dropped, the fresh one
    # is guided up and pressed home almost without overshoot, and the charging
    # handle is drawn back and RIDDEN forward. No slaps anywhere.
    "GloomcallerDmr": {
        "DURATION": 2.0,
        "TRACKS": {
            "weapon": [
                (0.00, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),
                (0.30, (-14.0, 3.0, -4.0), (0.02, -0.16, -0.24)),  # muzzle eased DOWN to a low ready
                (1.30, (-14.0, 3.0, -4.0), (0.02, -0.16, -0.24)),  # rock steady - barely a cant at all
                (1.55, (-9.0, 2.0, -3.0), (0.01, -0.11, -0.16)),
                (1.80, (-3.0, 1.0, -1.0), (0.00, -0.04, -0.05)),  # creeps back to the eyepiece
                (2.00, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),
            ],
            "mag": [
                (0.00, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),
                (0.26, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),  # hand settles on it, unhurried
                (0.44, (2.0, 0.0, 0.0), (0.00, 0.02, -0.34)),  # drawn straight DOWN out of the well
                (0.66, (6.0, 0.0, -8.0), (-0.30, 0.12, -1.70)),  # carried away to the left, not dropped
                (0.86, (8.0, 0.0, -14.0), (-0.62, 0.20, -2.55)),  # SET ASIDE, low and out of the way
                (1.02, (-8.0, 0.0, -10.0), (-0.48, 0.24, -2.45)),  # the fresh one taken up in its place
                (1.26, (-5.0, 0.0, -4.0), (-0.18, 0.10, -1.25)),  # rising slow, tracking back to centre
                (1.46, (-2.0, 0.0, 0.0), (0.00, 0.02, -0.24)),  # squared up on the well
                (1.58, (0.0, 0.0, 0.0), (0.00, 0.00, 0.02)),  # eased home, barely past
                (1.66, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),
                (2.00, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),
            ],
            "hand": [
                (0.00, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),
                (0.26, (0.0, 0.0, 0.0), (-0.03, 0.03, 0.05)),  # takes a full grip before anything moves
                (0.44, (2.0, 0.0, 0.0), (-0.02, 0.04, -0.30)),  # mirrors the mag all the way down...
                (0.66, (6.0, 0.0, -8.0), (-0.32, 0.14, -1.66)),  # ...out to the left with it
                (0.86, (8.0, 0.0, -14.0), (-0.64, 0.22, -2.51)),
                (1.02, (-8.0, 0.0, -10.0), (-0.50, 0.26, -2.41)),  # ...and back up with the fresh one
                (1.26, (-5.0, 0.0, -4.0), (-0.20, 0.12, -1.21)),
                (1.46, (-2.0, 0.0, 0.0), (-0.02, 0.04, -0.20)),
                (1.58, (0.0, 0.0, 0.0), (-0.03, 0.02, 0.06)),  # a press, not a shove
                (1.72, (0.0, -14.0, 0.0), (0.28, -0.12, 0.34)),  # up to the charging handle
                (1.84, (0.0, -14.0, 0.0), (0.28, -0.44, 0.34)),  # drawn back under control
                (1.92, (0.0, -6.0, 0.0), (0.22, -0.08, 0.28)),  # RIDDEN forward, never released
                (2.00, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),
            ],
            "action": [
                (0.00, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),
                (1.72, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),
                (1.84, (0.0, 0.0, 0.0), (0.00, -0.34, 0.00)),  # a slow full pull
                (1.92, (0.0, 0.0, 0.0), (0.00, 0.02, 0.00)),  # eased home - the faintest touch past
                (2.00, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),
            ],
        },
    },

    # Bolt-action single (1.2s, after EVERY shot): the gun tips LEFT so the
    # right-side port faces the camera, the hand lifts and hauls the bolt open,
    # dips for one round and presses it into the well, then runs the bolt
    # forward and turns it down.
    "FrostboreRifle": {
        "DURATION": 1.2,
        "TRACKS": {
            "weapon": [
                (0.00, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),
                (0.14, (4.0, -10.0, 16.0), (-0.08, -0.06, 0.05)),  # tips left, ejection port shown
                (0.30, (6.0, -12.0, 20.0), (-0.10, -0.06, 0.06)),  # held open to the camera
                (0.86, (5.0, -11.0, 18.0), (-0.09, -0.06, 0.05)),
                (1.00, (2.0, -4.0, 6.0), (-0.03, -0.02, 0.02)),  # levelling as the bolt runs home
                (1.08, (-2.0, 2.0, -3.0), (0.02, 0.01, -0.02)),  # the lock-down jolt
                (1.20, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),
            ],
            "action": [  # the bolt
                (0.00, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),
                (0.14, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),
                (0.24, (0.0, 0.0, -70.0), (0.00, 0.00, 0.06)),  # handle rotated UP, lugs unlocked
                (0.38, (0.0, 0.0, -70.0), (0.00, -0.34, 0.06)),  # hauled BACK, case flung clear
                (0.96, (0.0, 0.0, -70.0), (0.00, -0.34, 0.06)),  # port stays open for the round
                (1.03, (0.0, 0.0, -70.0), (0.00, 0.05, 0.06)),  # run FORWARD past the stop
                (1.09, (0.0, 0.0, 4.0), (0.00, 0.00, -0.01)),  # turned DOWN, locked
                (1.20, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),
            ],
            "mag": [  # the single round
                (0.00, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),
                (0.40, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),  # waits while the bolt is worked
                (0.52, (16.0, 0.0, 0.0), (0.14, -0.06, -1.30)),  # taken down with the hand
                (0.60, (24.0, 0.0, 0.0), (0.16, -0.08, -2.20)),  # off the belt
                (0.70, (-26.0, 0.0, 0.0), (0.14, 0.00, -1.00)),  # carried back up
                (0.80, (-12.0, 0.0, 0.0), (0.04, 0.06, -0.16)),  # nose over the open port
                (0.88, (0.0, 0.0, 0.0), (0.00, 0.02, 0.03)),  # thumbed down into the well
                (0.94, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),
                (1.20, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),
            ],
            "hand": [
                (0.00, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),
                (0.14, (0.0, 0.0, 0.0), (0.16, -0.18, 0.28)),  # up to the bolt knob
                (0.24, (0.0, 0.0, -70.0), (0.16, -0.14, 0.34)),  # lifts it with the bolt
                (0.38, (0.0, 0.0, -70.0), (0.16, -0.48, 0.34)),  # hauls it back, same path
                (0.52, (16.0, 0.0, 0.0), (0.16, -0.08, -1.26)),  # lets go and dips, round in hand...
                (0.60, (24.0, 0.0, 0.0), (0.18, -0.10, -2.16)),
                (0.70, (-26.0, 0.0, 0.0), (0.16, -0.02, -0.96)),
                (0.80, (-12.0, 0.0, 0.0), (0.06, 0.08, -0.12)),
                (0.88, (0.0, 0.0, 0.0), (0.02, 0.04, 0.06)),  # presses it in
                (0.96, (0.0, 0.0, -70.0), (0.16, -0.44, 0.34)),  # back to the knob
                (1.03, (0.0, 0.0, -70.0), (0.16, -0.05, 0.34)),  # runs it forward
                (1.09, (0.0, 0.0, 0.0), (0.16, -0.08, 0.30)),  # turns it down
                (1.20, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),
            ],
        },
    },

    # Five-chamber hand cannon (2.4s): half revolver, half field gun. Cylinder
    # swings out and dumps, then FIVE deliberate clicks - the hand fetching and
    # pressing a shell at each one - before the whole thing is heaved shut.
    "ThunderheadCannon": {
        "DURATION": 2.4,
        "TRACKS": {
            "weapon": [
                (0.00, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),
                (0.22, (16.0, -20.0, 18.0), (-0.14, -0.14, 0.10)),  # rolled left, heavy
                (0.40, (62.0, -28.0, 22.0), (-0.18, -0.30, 0.42)),  # muzzle straight up, the brass dumps
                (0.58, (20.0, -22.0, 17.0), (-0.15, -0.16, 0.12)),  # back to the loading angle
                (1.90, (19.0, -21.0, 16.0), (-0.14, -0.16, 0.11)),  # parked there for all five
                (2.06, (6.0, -8.0, 6.0), (-0.05, -0.06, 0.04)),  # heaved shut
                (2.20, (-6.0, 4.0, -5.0), (0.03, 0.03, -0.03)),  # the mass overshoots
                (2.40, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),
            ],
            "action": [  # the five-chamber cylinder
                # The five clicks are 72 deg each and nothing else touches the
                # cylinder's own axis, so the fifth one lands it on a WHOLE
                # turn: the shut position IS identity and the lock is the last
                # motion in the track. (Indexing by anything else forces a
                # spin AFTER the lock to reach identity by the final key - a
                # locked cylinder visibly whirring on inside the closed frame.)
                (0.00, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),
                (0.16, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),
                (0.28, (0.0, 58.0, 0.0), (-0.34, 0.00, -0.08)),  # swings way out, frame-left
                (0.42, (0.0, 62.0, 0.0), (-0.38, 0.00, -0.10)),  # tips with the dump
                (0.58, (0.0, 60.0, 0.0), (-0.36, 0.00, -0.09)),  # settles, chamber one up
                (0.82, (0.0, 60.0, 0.0), (-0.36, 0.00, -0.09)),  # still while a shell goes in
                (0.88, (0.0, 60.0, -72.0), (-0.36, 0.00, -0.09)),  # CLICK 1 - a fifth of a turn
                (1.08, (0.0, 60.0, -72.0), (-0.36, 0.00, -0.09)),
                (1.14, (0.0, 60.0, -144.0), (-0.36, 0.00, -0.09)),  # CLICK 2
                (1.34, (0.0, 60.0, -144.0), (-0.36, 0.00, -0.09)),
                (1.40, (0.0, 60.0, -216.0), (-0.36, 0.00, -0.09)),  # CLICK 3
                (1.60, (0.0, 60.0, -216.0), (-0.36, 0.00, -0.09)),
                (1.66, (0.0, 60.0, -288.0), (-0.36, 0.00, -0.09)),  # CLICK 4
                (1.86, (0.0, 60.0, -288.0), (-0.36, 0.00, -0.09)),
                (1.92, (0.0, 60.0, -360.0), (-0.36, 0.00, -0.09)),  # CLICK 5 - the turn closes
                (2.06, (0.0, 26.0, -360.0), (-0.16, 0.00, -0.04)),  # swinging shut
                (2.16, (0.0, -4.0, -360.0), (0.01, 0.00, 0.00)),  # slams past the frame
                (2.24, (0.0, 0.0, -360.0), (0.00, 0.00, 0.00)),  # LOCKED - and already home
                (2.40, (0.0, 0.0, -360.0), (0.00, 0.00, 0.00)),  # dead still to the last frame
            ],
            "mag": [  # one shell, five times, on the beat
                (0.00, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),
                (0.50, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),
                (0.58, (24.0, 0.0, 0.0), (0.12, 0.04, -2.30)),  # shell 1 out of the pouch
                (0.70, (-22.0, 0.0, 0.0), (-0.08, 0.06, -0.70)),  # up to the cylinder face
                (0.82, (0.0, 0.0, 0.0), (-0.02, 0.05, 0.03)),  # PRESSED into chamber 1
                (0.91, (24.0, 0.0, 0.0), (0.12, 0.04, -2.30)),  # shell 2
                (1.00, (-22.0, 0.0, 0.0), (-0.08, 0.06, -0.70)),
                (1.08, (0.0, 0.0, 0.0), (-0.02, 0.05, 0.03)),
                (1.17, (24.0, 0.0, 0.0), (0.12, 0.04, -2.30)),  # shell 3
                (1.26, (-22.0, 0.0, 0.0), (-0.08, 0.06, -0.70)),
                (1.34, (0.0, 0.0, 0.0), (-0.02, 0.05, 0.03)),
                (1.43, (24.0, 0.0, 0.0), (0.12, 0.04, -2.30)),  # shell 4
                (1.52, (-22.0, 0.0, 0.0), (-0.08, 0.06, -0.70)),
                (1.60, (0.0, 0.0, 0.0), (-0.02, 0.05, 0.03)),
                (1.69, (24.0, 0.0, 0.0), (0.12, 0.04, -2.30)),  # shell 5
                (1.78, (-22.0, 0.0, 0.0), (-0.08, 0.06, -0.70)),
                (1.86, (0.0, 0.0, 0.0), (-0.02, 0.05, 0.03)),
                (1.96, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),
                (2.40, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),
            ],
            "hand": [
                (0.00, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),
                (0.22, (0.0, 0.0, 0.0), (-0.10, 0.10, 0.28)),  # cups the heavy frame
                (0.50, (-18.0, 0.0, 0.0), (-0.12, 0.14, 0.34)),  # thumb across the chamber mouths
                (0.58, (24.0, 0.0, 0.0), (0.14, 0.06, -2.26)),  # dives for shell 1 - mirrors the mag
                (0.70, (-22.0, 0.0, 0.0), (-0.06, 0.08, -0.66)),
                (0.82, (0.0, 0.0, 0.0), (0.00, 0.07, 0.06)),  # the press
                (0.91, (24.0, 0.0, 0.0), (0.14, 0.06, -2.26)),
                (1.00, (-22.0, 0.0, 0.0), (-0.06, 0.08, -0.66)),
                (1.08, (0.0, 0.0, 0.0), (0.00, 0.07, 0.06)),
                (1.17, (24.0, 0.0, 0.0), (0.14, 0.06, -2.26)),
                (1.26, (-22.0, 0.0, 0.0), (-0.06, 0.08, -0.66)),
                (1.34, (0.0, 0.0, 0.0), (0.00, 0.07, 0.06)),
                (1.43, (24.0, 0.0, 0.0), (0.14, 0.06, -2.26)),
                (1.52, (-22.0, 0.0, 0.0), (-0.06, 0.08, -0.66)),
                (1.60, (0.0, 0.0, 0.0), (0.00, 0.07, 0.06)),
                (1.69, (24.0, 0.0, 0.0), (0.14, 0.06, -2.26)),
                (1.78, (-22.0, 0.0, 0.0), (-0.06, 0.08, -0.66)),
                (1.86, (0.0, 0.0, 0.0), (0.00, 0.07, 0.06)),  # fifth and last
                (2.00, (-8.0, 0.0, 0.0), (-0.14, 0.12, 0.24)),  # palm onto the cylinder
                (2.10, (0.0, 0.0, 0.0), (-0.06, 0.10, 0.14)),  # heaves it shut
                (2.40, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),
            ],
        },
    },

    # Break-action double (1.7s): the whole gun HINGES - the weapon track pitches
    # the muzzle hard down and holds it there while two shells are thumbed into
    # the breech, then it is whipped shut and snaps past level.
    "BasaltScattergun": {
        "DURATION": 1.7,
        "TRACKS": {
            "weapon": [
                (0.00, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),
                (0.10, (-6.0, 8.0, -6.0), (0.04, -0.06, -0.04)),  # thumb finds the top lever
                (0.26, (-52.0, 6.0, -8.0), (0.06, -0.24, -0.30)),  # BREAKS - muzzle swings down hard
                (0.34, (-46.0, 6.0, -8.0), (0.06, -0.22, -0.26)),  # rebounds off the hinge stop
                (1.24, (-46.0, 6.0, -8.0), (0.06, -0.22, -0.26)),  # gaping open for both shells
                (1.42, (-16.0, 4.0, -5.0), (0.03, -0.10, -0.10)),  # whipped up to close
                (1.50, (10.0, -2.0, 3.0), (-0.02, 0.04, 0.08)),  # SNAP - overshoots past level
                (1.58, (-4.0, 1.0, -1.0), (0.01, -0.01, -0.02)),  # settles back down
                (1.70, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),
            ],
            "action": [  # the barrels on the hinge
                (0.00, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),
                (0.10, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),
                (0.26, (-54.0, 0.0, 0.0), (0.00, 0.10, -0.16)),  # breech yawns open
                (0.34, (-48.0, 0.0, 0.0), (0.00, 0.08, -0.13)),
                (1.24, (-48.0, 0.0, 0.0), (0.00, 0.08, -0.13)),
                (1.42, (-14.0, 0.0, 0.0), (0.00, 0.03, -0.04)),  # swinging closed
                (1.50, (6.0, 0.0, 0.0), (0.00, -0.02, 0.02)),  # slams past the face
                (1.58, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),
                (1.70, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),
            ],
            "mag": [  # a shell, twice
                (0.00, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),
                (0.40, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),
                (0.52, (20.0, 0.0, 0.0), (0.14, 0.02, -2.30)),  # shell 1 off the belt loop
                (0.66, (-16.0, 0.0, 0.0), (0.06, 0.10, -0.60)),  # up over the open breech
                (0.78, (0.0, 0.0, 0.0), (0.00, 0.06, -0.04)),  # thumbed into the left chamber
                (0.86, (0.0, 0.0, 0.0), (0.00, 0.01, 0.00)),
                (0.96, (20.0, 0.0, 0.0), (0.14, 0.02, -2.30)),  # shell 2, same path
                (1.10, (-16.0, 0.0, 0.0), (0.06, 0.10, -0.60)),
                (1.22, (0.0, 0.0, 0.0), (0.00, 0.06, -0.04)),
                (1.30, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),
                (1.70, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),
            ],
            "hand": [
                (0.00, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),
                (0.20, (0.0, 0.0, 0.0), (-0.04, 0.06, 0.10)),  # rises as the gun breaks
                (0.40, (0.0, 0.0, 0.0), (0.02, 0.06, 0.02)),
                (0.52, (20.0, 0.0, 0.0), (0.16, 0.04, -2.26)),  # mirrors shell 1 down and up...
                (0.66, (-16.0, 0.0, 0.0), (0.08, 0.12, -0.56)),
                (0.78, (0.0, 0.0, 0.0), (0.02, 0.08, 0.00)),
                (0.86, (0.0, 0.0, 0.0), (0.02, 0.03, 0.02)),
                (0.96, (20.0, 0.0, 0.0), (0.16, 0.04, -2.26)),  # ...and shell 2
                (1.10, (-16.0, 0.0, 0.0), (0.08, 0.12, -0.56)),
                (1.22, (0.0, 0.0, 0.0), (0.02, 0.08, 0.00)),
                (1.32, (0.0, 0.0, 0.0), (0.04, 0.10, 0.04)),  # takes the forend
                (1.46, (-10.0, 0.0, 0.0), (0.04, 0.14, 0.10)),  # whips the gun shut on it
                (1.54, (4.0, 0.0, 0.0), (0.03, 0.06, 0.02)),
                (1.70, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),
            ],
        },
    },

    # Muzzle-loader (2.2s): the gun goes muzzle-UP and STAYS there. The hand
    # fetches a fistful of scrap, holds it over the bore and pours - a long
    # deliberate beat with almost no motion - then the rammer tamps twice.
    "GraveBlunderbuss": {
        "DURATION": 2.2,
        "TRACKS": {
            "weapon": [
                (0.00, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),
                (0.26, (58.0, -12.0, 10.0), (-0.06, -0.22, 0.30)),  # muzzle heaved UP
                (0.40, (64.0, -12.0, 10.0), (-0.06, -0.24, 0.34)),  # near vertical, bore to the sky
                (1.60, (62.0, -12.0, 10.0), (-0.06, -0.23, 0.33)),  # held for the pour and both tamps
                (1.84, (24.0, -6.0, 5.0), (-0.02, -0.10, 0.14)),  # coming back down
                (2.00, (-8.0, 2.0, -2.0), (0.02, 0.03, -0.04)),  # falls past level under its own weight
                (2.20, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),
            ],
            "mag": [  # a fistful of scrap
                (0.00, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),
                (0.34, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),
                (0.48, (26.0, 0.0, 0.0), (0.16, 0.04, -2.30)),  # scooped out of the pouch
                (0.66, (-40.0, 0.0, 0.0), (0.02, 0.16, 0.98)),  # hoisted above the muzzle
                (0.80, (-70.0, 0.0, 0.0), (0.00, 0.14, 1.16)),  # tipped over the bore
                (1.02, (-70.0, 0.0, 0.0), (0.00, 0.12, 1.10)),  # POURING - the long hanging beat
                (1.16, (-30.0, 0.0, 0.0), (0.00, 0.06, 0.30)),  # last of it rattles down
                (1.26, (0.0, 0.0, 0.0), (0.00, 0.02, 0.02)),  # gone into the barrel
                (1.34, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),
                (2.20, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),
            ],
            "action": [  # the rammer
                (0.00, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),
                (1.30, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),
                (1.40, (0.0, 0.0, 0.0), (0.00, 0.00, 0.55)),  # drawn clear above the muzzle
                (1.50, (0.0, 0.0, 0.0), (0.00, 0.00, -0.10)),  # TAMP one, driven past home
                (1.60, (0.0, 0.0, 0.0), (0.00, 0.00, 0.42)),  # hauled back up
                (1.68, (0.0, 0.0, 0.0), (0.00, 0.00, -0.12)),  # TAMP two, harder
                (1.76, (0.0, 0.0, 0.0), (0.00, 0.00, 0.06)),
                (1.84, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),
                (2.20, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),
            ],
            "hand": [
                (0.00, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),
                (0.26, (0.0, 0.0, 0.0), (-0.04, 0.08, 0.16)),  # comes up alongside the barrel
                (0.48, (26.0, 0.0, 0.0), (0.18, 0.06, -2.26)),  # dives to the scrap pouch
                (0.66, (-40.0, 0.0, 0.0), (0.04, 0.18, 1.02)),  # carries it up - same path as the mag
                (0.80, (-70.0, 0.0, 0.0), (0.02, 0.16, 1.20)),
                (1.02, (-70.0, 0.0, 0.0), (0.02, 0.14, 1.14)),  # holds it there, pouring
                (1.16, (-30.0, 0.0, 0.0), (0.02, 0.08, 0.34)),
                (1.26, (0.0, 0.0, 0.0), (0.02, 0.04, 0.06)),
                (1.40, (0.0, 0.0, 0.0), (0.00, 0.02, 0.60)),  # takes the rammer, lifts it
                (1.50, (0.0, 0.0, 0.0), (0.00, 0.02, -0.06)),  # rams with it
                (1.60, (0.0, 0.0, 0.0), (0.00, 0.02, 0.46)),
                (1.68, (0.0, 0.0, 0.0), (0.00, 0.02, -0.08)),  # and again
                (1.80, (0.0, 0.0, 0.0), (0.00, 0.04, 0.20)),  # clears the muzzle
                (2.20, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),
            ],
        },
    },

    # Flintlock (1.53s, after every shot): three separate errands - powder
    # flicked into the pan and the frizzen shut over it, then the gun goes
    # muzzle-up for the ball and one long ram, and it ends on the cock being
    # thumbed back to a small priming snap.
    "MireFlintlock": {
        "DURATION": 1.53,
        "TRACKS": {
            "weapon": [
                (0.00, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),
                (0.14, (10.0, -18.0, 22.0), (-0.12, -0.10, 0.10)),  # rolled left, lock face up
                (0.42, (12.0, -18.0, 22.0), (-0.12, -0.10, 0.10)),  # held flat so the pan holds powder
                (0.60, (48.0, -10.0, 12.0), (-0.06, -0.20, 0.28)),  # muzzle swings up for the ball
                (1.28, (50.0, -10.0, 12.0), (-0.06, -0.20, 0.28)),  # stays up through the ram
                (1.40, (14.0, -14.0, 18.0), (-0.10, -0.10, 0.12)),  # back down to the lock
                (1.48, (2.0, -3.0, 4.0), (-0.02, -0.02, 0.02)),
                (1.53, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),
            ],
            "action": [  # frizzen / cock
                (0.00, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),
                (0.12, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),
                (0.20, (0.0, 0.0, -46.0), (0.00, 0.02, 0.04)),  # frizzen flicked open, pan bare
                (0.44, (0.0, 0.0, -46.0), (0.00, 0.02, 0.04)),  # open while the powder goes in
                # Shut means SHUT: a frizzen left ajar spills the priming, and
                # the gun then goes muzzle-up for the ball with the pan open.
                (0.52, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),  # snapped shut over the charge
                (1.36, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),  # sealed through the whole ram
                (1.44, (0.0, 0.0, -36.0), (0.00, -0.03, 0.03)),  # cock thumbed back
                (1.50, (0.0, 0.0, 5.0), (0.00, 0.01, -0.01)),  # the little priming SNAP
                (1.53, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),
            ],
            "mag": [  # powder horn first, then the ball
                (0.00, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),
                (0.14, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),
                (0.24, (22.0, 0.0, 0.0), (0.14, 0.04, -2.20)),  # horn off the belt
                (0.34, (-34.0, 0.0, 0.0), (-0.10, 0.06, 0.16)),  # tipped over the pan
                (0.44, (-40.0, 0.0, 0.0), (-0.12, 0.05, 0.12)),  # the FLICK - powder in
                (0.54, (0.0, 0.0, 0.0), (0.02, 0.02, -0.30)),  # dropped away
                (0.70, (24.0, 0.0, 0.0), (0.14, 0.06, -2.20)),  # the ball, off the belt
                (0.86, (-24.0, 0.0, 0.0), (0.02, 0.14, 1.06)),  # up over the raised muzzle
                (0.98, (-6.0, 0.0, 0.0), (0.00, 0.12, 0.74)),  # dropped into the bore
                (1.08, (0.0, 0.0, 0.0), (0.00, 0.05, 0.10)),  # sunk out of sight
                (1.16, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),
                (1.53, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),
            ],
            "hand": [
                (0.00, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),
                (0.14, (0.0, 0.0, 0.0), (-0.06, 0.06, 0.14)),  # up to the lock
                (0.24, (22.0, 0.0, 0.0), (0.16, 0.06, -2.16)),  # to the belt for the horn
                (0.34, (-34.0, 0.0, 0.0), (-0.08, 0.08, 0.20)),  # carries it to the pan
                (0.44, (-40.0, 0.0, 0.0), (-0.10, 0.07, 0.16)),  # flicks the charge in
                (0.52, (-20.0, 0.0, 0.0), (-0.08, 0.06, 0.10)),  # thumb shuts the frizzen
                (0.70, (24.0, 0.0, 0.0), (0.16, 0.08, -2.16)),  # back down for the ball
                (0.86, (-24.0, 0.0, 0.0), (0.04, 0.16, 1.10)),  # up over the muzzle with it
                (0.98, (-6.0, 0.0, 0.0), (0.02, 0.14, 0.78)),
                (1.08, (0.0, 0.0, 0.0), (0.02, 0.08, 0.16)),  # feeds it into the bore
                (1.18, (0.0, 0.0, 0.0), (0.00, 0.06, 1.14)),  # takes the ramrod, up at the muzzle
                (1.30, (0.0, 0.0, 0.0), (0.00, 0.04, -0.10)),  # ONE long ram, all the way down
                (1.40, (0.0, 0.0, 0.0), (-0.06, 0.00, 0.22)),  # clears, reaches for the cock
                (1.46, (0.0, 0.0, 0.0), (-0.08, -0.05, 0.14)),  # thumbs it back
                (1.53, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),
            ],
        },
    },

    # Crossbow (1.1s, after every shot): a bolt is taken from the quiver and
    # laid down into the channel, then the hand hooks the string and hauls it
    # and the slider back TOGETHER until the nut catches with a jolt.
    "GatorjawCrossbow": {
        "DURATION": 1.1,
        "TRACKS": {
            "weapon": [
                (0.00, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),
                (0.12, (-6.0, 10.0, -12.0), (0.08, -0.08, -0.06)),  # tips over so the channel shows
                (0.50, (-6.0, 10.0, -12.0), (0.08, -0.08, -0.06)),
                (0.72, (-14.0, 8.0, -10.0), (0.06, -0.16, -0.10)),  # leans into the draw
                (0.88, (2.0, -3.0, 3.0), (-0.02, 0.04, 0.03)),  # the nut CATCHES - a jolt back
                (1.00, (-2.0, 1.0, -1.0), (0.01, -0.01, -0.01)),
                (1.10, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),
            ],
            "mag": [  # the bolt
                # Same rule as the bow: the SEATED bolt has to leave down the
                # rail before a fresh one is fetched. Starting this track at
                # the quiver ran the spent bolt backwards out of the channel -
                # the gun un-firing on every shot.
                (0.00, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),  # still in the channel, as the shot leaves
                (0.05, (0.0, 0.0, 0.0), (0.04, 2.00, -0.06)),  # streaks away down the rail line
                (0.14, (18.0, 0.0, 0.0), (-0.22, 0.20, -2.10)),  # the next one, down in the quiver
                (0.24, (24.0, 0.0, 0.0), (-0.34, 0.02, -2.40)),  # plucked out
                (0.38, (-26.0, 0.0, 0.0), (-0.10, 0.16, 1.00)),  # swung up clear ABOVE the rail
                (0.48, (-6.0, 0.0, 0.0), (0.00, 0.10, 0.34)),  # LAID down into the channel from above
                (0.56, (0.0, 0.0, 0.0), (0.00, 0.06, 0.00)),  # slid back against the string
                (0.64, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),
                (1.10, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),
            ],
            "action": [  # string slider
                (0.00, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),
                (0.60, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),
                (0.74, (0.0, 0.0, 0.0), (0.00, -0.26, 0.00)),  # hauled back with the hand
                (0.84, (0.0, 0.0, 0.0), (0.00, -0.34, 0.00)),  # over the nut
                (0.90, (0.0, 0.0, 0.0), (0.00, -0.30, 0.00)),  # eases forward onto the sear - LOCKED
                (1.10, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),
            ],
            "hand": [
                (0.00, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),
                (0.06, (0.0, 0.0, 0.0), (-0.04, 0.04, 0.08)),  # rises into frame as the bolt clears
                (0.14, (18.0, 0.0, 0.0), (-0.20, 0.22, -2.06)),  # dives to the quiver...
                (0.24, (24.0, 0.0, 0.0), (-0.32, 0.04, -2.36)),  # ...and plucks a fresh one
                (0.38, (-26.0, 0.0, 0.0), (-0.08, 0.18, 1.04)),  # mirrors it back up clear ABOVE the rail
                (0.48, (-6.0, 0.0, 0.0), (0.02, 0.12, 0.38)),
                (0.56, (0.0, 0.0, 0.0), (0.02, 0.08, 0.04)),  # presses it back to the string
                (0.64, (0.0, 0.0, 0.0), (0.00, 0.06, 0.10)),  # hooks fingers over the string
                (0.74, (0.0, 0.0, 0.0), (0.00, -0.22, 0.14)),  # hauls back with the slider
                (0.84, (0.0, 0.0, 0.0), (0.00, -0.32, 0.16)),  # to the nut
                (0.92, (0.0, 0.0, 0.0), (0.00, -0.24, 0.20)),  # releases once it holds
                (1.10, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),
            ],
        },
    },

    # Harpoon gun (0.85s, after every shot): no magazine well at all - a fresh
    # iron is swung up out of the low-LEFT rack in one arc, held over the rail,
    # dropped onto it from ABOVE and pressed home until the latch clicks.
    "AbyssalHarpooner": {
        "DURATION": 0.85,
        "TRACKS": {
            "weapon": [
                (0.00, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),
                (0.10, (-4.0, 6.0, -8.0), (0.06, -0.06, -0.04)),  # dips to lay the rail flat
                (0.44, (-4.0, 6.0, -8.0), (0.06, -0.06, -0.04)),
                (0.56, (-10.0, 5.0, -7.0), (0.05, -0.04, -0.12)),  # sags as the iron's weight lands
                (0.66, (4.0, -3.0, 4.0), (-0.03, 0.03, 0.05)),  # the CLICK kicks it back up
                (0.76, (-2.0, 1.0, -1.0), (0.01, -0.01, -0.01)),
                (0.85, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),
            ],
            "mag": [  # the iron
                (0.00, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),
                (0.08, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),
                (0.18, (16.0, 0.0, -14.0), (-0.42, 0.06, -1.60)),  # carried down and out to the left
                (0.28, (22.0, 0.0, -22.0), (-0.70, 0.04, -2.30)),  # gripped low-left in the rack
                (0.42, (-34.0, 0.0, -10.0), (-0.24, 0.20, 1.12)),  # swung up in one arc, high ABOVE the rail
                (0.52, (-12.0, 0.0, -2.0), (-0.04, 0.12, 0.62)),  # held over it, nose squared
                (0.60, (0.0, 0.0, 0.0), (0.00, 0.02, -0.05)),  # dropped in and pressed past the stop
                (0.66, (0.0, 0.0, 0.0), (0.00, 0.00, 0.01)),
                (0.72, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),
                (0.85, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),
            ],
            "hand": [
                (0.00, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),
                (0.08, (0.0, 0.0, 0.0), (-0.04, 0.04, 0.08)),  # up into frame
                (0.18, (16.0, 0.0, -14.0), (-0.40, 0.08, -1.56)),  # same arc as the iron, throughout
                (0.28, (22.0, 0.0, -22.0), (-0.68, 0.06, -2.26)),
                (0.42, (-34.0, 0.0, -10.0), (-0.22, 0.22, 1.16)),
                (0.52, (-12.0, 0.0, -2.0), (-0.02, 0.14, 0.66)),
                (0.60, (0.0, 0.0, 0.0), (0.02, 0.04, 0.00)),  # the heel of the hand drives it down
                (0.68, (0.0, 0.0, 0.0), (0.02, 0.02, 0.06)),
                (0.85, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),
            ],
            "action": [  # the rail latch
                (0.00, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),
                (0.50, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),
                (0.60, (0.0, 0.0, 0.0), (0.00, 0.00, -0.10)),  # shoved down by the incoming iron
                (0.66, (0.0, 0.0, 0.0), (0.00, 0.00, 0.04)),  # springs back over it - CLICK
                (0.72, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),
                (0.85, (0.0, 0.0, 0.0), (0.00, 0.00, 0.00)),
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
        cam_data = bpy.data.cameras.new("Cam")
        cam_data.lens_unit = "FOV"
        cam_data.angle = math.radians(60)
        cam = bpy.data.objects.new("Cam", cam_data)
        scene.collection.objects.link(cam)
        scene.camera = cam
        # A framed 3/4 view AT the gun (the original camera stared past it -
        # every still rendered near-black; found by the choreography author).
        cam.location = PREVIEW_GUN_AT + Vector((-1.6, -3.4, 1.2))
        direction = PREVIEW_GUN_AT - cam.location
        cam.rotation_euler = direction.to_track_quat("-Z", "Y").to_euler()
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
