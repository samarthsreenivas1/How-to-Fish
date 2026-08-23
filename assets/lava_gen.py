# lava_gen.py
# Generates the volcano's stylised lava texture as a tiling PNG. Same Blender
# pipeline as water_gen.py (bpy ships numpy and writes PNGs):
#
#   blender --background --python assets/lava_gen.py -- assets/lava.png
#
# The look is the "yellow lava" reference: a bright molten field broken into
# rounded organic cells by darker orange veins - cooling crust plates with
# glowing cracks between them. It's built from the same periodic, domain-warped
# Voronoi diagram the water uses, but OPAQUE and coloured: distance to the
# nearest cell border (f2 - f1) drives a blend from bright yellow in the middle
# of a plate to deep orange in the cracks, plus a little molten brightness
# noise so no two plates read identical.
#
# Unlike the water tile (transparent lines over the part colour), this tile is
# fully opaque - the lava's colour IS the texture - and it's applied through a
# MaterialVariant (tiles by studs on the mesh, no UVs needed), so nothing about
# the lava mesh has to change.
#
# Authoring contract (Shared/Config/Lava.luau relies on this):
#   - The tile wraps seamlessly in U and V (periodic lattice + wrap-around
#     distances + whole-cycle warp), so it tiles across the lake with no seams.

import os
import random
import sys

import bpy
import numpy as np

# ---------------------------------------------------------------- parameters

SIZE = 512  # pixels per side
CELLS = 5  # Voronoi points per axis; fewer = bigger plates (the reference is chunky)
SEED = 23

VEIN_WIDTH = 0.38  # how far the orange crack reaches in from a border (fraction of a cell)
VEIN_SOFTNESS = 0.8  # 0 = hard cracks, 1 = very soft molten blend

# Domain warp: (whole cycles per tile, amplitude as a fraction of a cell). Two
# incommensurate terms per axis so the plates read organic, not polygonal.
WARP = [(2, 0.34), (3, 0.18)]

# sRGB. Bright yellow plate centres, deep orange cracks, and a hot near-white
# fleck at the very middle of a plate for the molten sheen.
YELLOW = np.array((255, 214, 48), dtype=np.float32)
ORANGE = np.array((225, 96, 12), dtype=np.float32)
CORE = np.array((255, 245, 180), dtype=np.float32)


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

    # Warp the sampling position; each term is a whole number of cycles across
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

    edge = (f2 - f1) / cell  # 0 exactly on a cell border, grows toward a plate's middle

    # crack = 1 in the veins, 0 in the plate centres.
    crack = 1.0 - smoothstep(VEIN_WIDTH * (1 - VEIN_SOFTNESS), VEIN_WIDTH, edge)
    # core = 1 only deep inside a plate, for the hot molten sheen (kept small).
    core = smoothstep(0.72, 0.98, edge)

    # A gentle large-scale brightness variation so plates differ - subtle, so
    # the field stays uniformly bright like the reference.
    tone = 0.94 + 0.06 * np.sin(2 * np.pi * 2 * xs / SIZE + 1.3) * np.sin(2 * np.pi * 2 * ys / SIZE)

    rgb = YELLOW[None, None, :] * (1 - crack[..., None]) + ORANGE[None, None, :] * crack[..., None]
    rgb = rgb * (1 - core[..., None]) + CORE[None, None, :] * core[..., None]
    rgb = np.clip(rgb * tone[..., None], 0, 255)

    image = np.ones((SIZE, SIZE, 4), dtype=np.float32)
    image[..., :3] = rgb / 255.0
    image[..., 3] = 1.0  # opaque
    return image


# ---------------------------------------------------------------- output


def save_png(image, path, name):
    img = bpy.data.images.new(name, SIZE, SIZE, alpha=True)
    img.pixels.foreach_set(np.flipud(image).ravel())  # bpy rows run bottom-up
    img.filepath_raw = os.path.abspath(path)
    img.file_format = "PNG"
    img.save()


def main():
    args = sys.argv[sys.argv.index("--") + 1 :]
    if len(args) != 1:
        raise SystemExit("usage: lava_gen.py -- <lava.png>")

    save_png(render(random.Random(SEED)), args[0], "lava")

    print(f"[lava_gen] exported {args[0]}")
    print(f"[lava_gen] {SIZE}px tile, {CELLS}x{CELLS} plates")
    print("[lava_gen] upload it in Studio (Asset Manager > Import) and paste the id into Shared/Config/Lava.luau")


main()
