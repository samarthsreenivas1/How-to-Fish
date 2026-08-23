# water_gen.py
# Generates the ocean's tiling "caustics" texture as a PNG. Same Blender
# pipeline as the meshes (bpy ships numpy and can write PNGs, so there is no
# second toolchain to install):
#
#   blender --background --python assets/water_gen.py -- assets/water.png
#
# The look is the stylised-water reference: a flat bright blue plane with
# pale, wavy, cell-like lines drifting across it. The lines are the edges of a
# jittered Voronoi diagram (distance to the 2nd-nearest point minus distance
# to the nearest - small near an edge), domain-warped with periodic sines so
# they bend instead of reading as straight polygon borders. Everything else
# in the tile is fully transparent, so the part colour underneath IS the
# water colour; WorldService lays the same tile twice at different scales and
# OceanController scrolls the two layers against each other.
#
# Authoring contract (Shared/Config/Ocean.luau relies on this):
#   - The tile wraps seamlessly in U and V. The Voronoi points live on a
#     periodic lattice and every distance is measured with wrap-around, and
#     the warp uses whole-number frequencies over the tile, so the right/top
#     edges are the left/bottom edges by construction.

import os
import random
import sys

import bpy
import numpy as np

# ---------------------------------------------------------------- parameters

SIZE = 512  # pixels per side
CELLS = 6  # Voronoi points per axis; fewer = bigger, lazier cells
SEED = 11

LINE_WIDTH = 0.26  # edge thickness, fraction of a cell
LINE_SOFTNESS = 0.55  # 0 = hard-edged lines, 1 = very soft
MAX_ALPHA = 0.92

# Domain warp: (frequency in whole cycles per tile, amplitude as a fraction of
# a cell). Two incommensurate terms per axis so the bends don't line up.
WARP = [(2, 0.22), (3, 0.12)]

LINE_COLOR = (226, 250, 255)  # sRGB; nearly white with a cyan cast


# ---------------------------------------------------------------- raster


def smoothstep(edge0, edge1, x):
    t = np.clip((x - edge0) / (edge1 - edge0), 0.0, 1.0)
    return t * t * (3 - 2 * t)


def render(rng):
    cell = SIZE / CELLS

    # Periodic jittered lattice of feature points.
    points = []
    for i in range(CELLS):
        for j in range(CELLS):
            points.append(((i + rng.random()) * cell, (j + rng.random()) * cell))
    points = np.array(points)

    ys, xs = np.mgrid[0:SIZE, 0:SIZE].astype(np.float32) + 0.5

    # Warp the sampling position. Each term is a whole number of cycles across
    # the tile so the warp itself tiles.
    wx, wy = xs.copy(), ys.copy()
    for k, (freq, amp) in enumerate(WARP):
        phase = rng.uniform(0, 2 * np.pi)
        wx += np.sin(2 * np.pi * freq * ys / SIZE + phase) * amp * cell
        wy += np.sin(2 * np.pi * freq * xs / SIZE + phase * 0.7 + k) * amp * cell

    # Distance to every point with wrap-around, then the two nearest.
    dx = (wx[..., None] - points[:, 0] + SIZE / 2) % SIZE - SIZE / 2
    dy = (wy[..., None] - points[:, 1] + SIZE / 2) % SIZE - SIZE / 2
    dist = np.sqrt(dx * dx + dy * dy)
    dist.sort(axis=-1)
    f1, f2 = dist[..., 0], dist[..., 1]

    edge = (f2 - f1) / cell  # 0 exactly on a cell border
    line = 1.0 - smoothstep(LINE_WIDTH * (1 - LINE_SOFTNESS), LINE_WIDTH, edge)
    alpha = line * MAX_ALPHA

    image = np.zeros((SIZE, SIZE, 4), dtype=np.float32)
    image[..., 0] = LINE_COLOR[0] / 255.0
    image[..., 1] = LINE_COLOR[1] / 255.0
    image[..., 2] = LINE_COLOR[2] / 255.0
    image[..., 3] = alpha
    return image


# ---------------------------------------------------------------- output


def save_png(image, path, name):
    # Blender's byte-buffer images store exactly the values written, so these
    # are sRGB numbers going straight to the file - no colour transform.
    img = bpy.data.images.new(name, SIZE, SIZE, alpha=True)
    img.pixels.foreach_set(np.flipud(image).ravel())  # bpy rows run bottom-up
    # Absolute on purpose: Blender resolves a relative filepath against its own
    # install directory, not the shell's working directory.
    img.filepath_raw = os.path.abspath(path)
    img.file_format = "PNG"
    img.save()


def main():
    args = sys.argv[sys.argv.index("--") + 1 :]
    if len(args) != 1:
        raise SystemExit("usage: water_gen.py -- <water.png>")

    save_png(render(random.Random(SEED)), args[0], "water")

    print(f"[water_gen] exported {args[0]}")
    print(f"[water_gen] {SIZE}px tile, {CELLS}x{CELLS} cells")
    print("[water_gen] upload it in Studio (Asset Manager > Import) and paste the id into Shared/Config/Ocean.luau")


main()
