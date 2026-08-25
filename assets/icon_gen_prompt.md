# Icon generation prompt (for Gemini / Nano Banana / Imagen) — one-shot sheet

All 36 missing icons in a single generation: one image, a 6×6 contact
sheet, one icon per cell, in a fixed reading order (left-to-right,
top-to-bottom) so each cell can be identified and cropped afterward.

Reference images to attach alongside this prompt when available (they exist
in this repo): `assets/rod_preview.png` and `assets/weapon_preview.png` —
Blender renders of every rod/weapon variant lined up. Tell Gemini to match
the Voltline/Brineheart rod and Tidebomb Maul/Voltfang/Heartrender weapon
silhouettes against those references closely.

**After generating:** crop each of the 36 cells out individually at equal
intervals. A single shared-canvas generation can't give each cell its own
alpha channel, so plan on a background-removal pass per crop (Gemini can do
this per-image too, or any bg-remove tool) before uploading to Studio's
Asset Manager — Studio icons need transparency to sit cleanly in the UI's
gradient tiles.

---

## PASTE THIS WHOLE PROMPT INTO GEMINI

```
Generate a single image: a 6×6 contact sheet of 36 equal-sized square
cells arranged in a strict grid, read left-to-right then top-to-bottom,
with even, generous padding/margins between every cell so they can be
cropped apart afterward at regular intervals. Do not draw grid lines or
dividers. Each cell contains exactly ONE separate, self-contained object —
never let two cells' contents overlap, touch, or blend into each other.
Put a small, plain, clean text caption in a consistent spot just below
each object (its name, given below) so cells can be identified.

STYLE — apply identically to every cell:
Stylized low-poly 3D render, chunky faceted geometry, flat matte "toy
plastic" shading (SmoothPlastic material — no PBR reflections, no
photorealism, no fine surface texture), matching a Roblox low-poly game's
Blender-generated asset style. Each object is centered in its cell, angled
in a 3/4 front-left perspective (camera slightly above, looking
down-and-across), filling about 70% of the cell. Dramatic single key light
from the upper-left per object, soft cool fill from the lower-right, a
soft contact shadow directly beneath each object. No props, no scenery,
no borders per cell. Background of the whole sheet: flat solid dark navy
(#0C1822), uniform across the entire image.

Any glowing/neon part called out below should render as a saturated
emissive light with a soft bloom halo — distinctly brighter and "lit from
within" versus the object's matte surfaces, not just a bright flat color.
Keep colors flat, saturated, and true to the RGB values given — no
gradients, patina, or extra materials beyond what's described.

The 36 cells, in order:

1. Voltline Rod — an "electrode whip" fishing rod: lean straight dark-blue
   rod blank, a glowing helical wire coil wound up the shaft like a spring,
   the tip splits into a forked lightning-bolt shape (two glowing prongs),
   a cylindrical battery canister slung under the butt, pale nacre-colored
   hardware, glowing electric-blue line and small quill float.

2. Brineheart Rod — deep red heartwood rod shaft that swells around a
   glowing red heart-core orb caged in curved bone ribs near the handle,
   backswept thorny barbs thinning toward the tip, bone-white hardware
   (some glowing red), spiked bone drum reel, broad glowing red pear
   float. Reads as grown, not built — the most substantial rod here.

3. Tidebomb Maul — tan driftwood haft topped by a whole spiked sea-urchin
   head: purple-grey sphere bristling with long spines in every direction
   (three rings plus one on top); the outer third of every spine glows
   warm orange, base stays matte. Dark cord-wrapped grip.

4. Voltfang — narrow fast blade shaped like a tuning fork, splitting into
   two slender prongs near the tip, pale iridescent nacre color, dark
   plain handle/crossguard, a glowing electric-blue arc bridging the gap
   between the prongs plus a thin glowing blue line up the blade's spine.

5. Heartrender — broad leaf-shaped blade, three stacked tapering slabs,
   deep red blade color, dark heartwood handle, heavy crossguard with a
   swept horn on each end, a bright glowing red heart-shaped core set into
   the blade center with thin glowing red veins branching up and down it.

6. Grub Worm — fat, plump segmented brown worm (RGB 150,116,92), curled
   slightly, threaded onto a small hook.

7. Chum — a small irregular clump of mashed tan-brown bait chum (RGB
   176,138,104), faintly wet-looking, no hook.

8. Shiny Minnow — small pale-blue-silver baitfish lure (RGB 168,198,220)
   with a glinting highlight along its side, on a small hook.

9. Fortune Fly — a gilded golden fishing fly (RGB 240,202,96): a hook
   wrapped in fine gold thread with small feather fibers splayed out.

10. Glowchum — soft irregular chum lump glowing faintly pale cyan from
    within (RGB 150,226,236), gentle emissive light not solid color.

11. Bloodbait — dark wet-looking clump of ground red-brown chum (RGB
    196,92,72), glistening surface, ominous but stylized, not gory.

12. Gravelure — heavy weighted metallic-green lure (RGB 120,200,150),
    small elongated pebble/sinker shape with a hook through it.

13. Frenzy Bait — fiery red-orange lure clump (RGB 228,84,64), jagged
    spiky silhouette suggesting motion and heat.

14. Venom Roe — small cluster of sickly green fish roe/eggs (RGB
    160,214,120), glistening, clumped in a rounded mound.

15. Split Roe — cluster of pale cream-yellow fish eggs (RGB 236,226,168),
    one or two cracked open with a faint warm glow inside.

16. Gilded Chum — golden coin-flecked chum clump (RGB 255,206,110), small
    flat gold coin fragments studding a tan-gold mashed base.

17. Leviathan's Call — a grim ceremonial lure knotted from small
    trophies (a tiny spine, claw, scale, fang bound with cord), soft
    glowing teal light (RGB 120,255,214) from its center, ominous and
    important-looking.

18. Skitterfin — a single springy olive-green fin (RGB 128,140,92), stiff
    and stilt-like, as if snapped off a fish.

19. Brine Gland — small glossy green organic sac (RGB 86,150,96), slightly
    bulbous and wet-looking.

20. Gilded Shell — broken shell shard (RGB 230,190,110), inner surface
    crusted with small embedded gold coin flecks.

21. Moonjelly — small translucent pale-blue gelatinous blob (RGB
    200,214,236), glowing faintly from within, subtle not bright.

22. Tidebomb Spine — single long tapering purple spine (RGB 150,90,146),
    tip has a subtle emissive glow.

23. Lurker Hide — folded scrap of sand-mottled tan hide (RGB 196,176,130),
    mottled with darker speckled patches.

24. Nacre — curved pale iridescent shell shard (RGB 226,232,240), rainbow-
    tinted highlights across its surface.

25. Volt Gland — glossy electric-blue organic sac (RGB 120,220,255), tiny
    glowing blue sparks crackling faintly around it.

26. Brineheart (material) — small stylized teal heart shape (RGB
    120,255,214), cold and still, faint steady glow (not pulsing).

27. Ember — single glowing orange coal (RGB 240,132,52), faceted like a
    small chunk of coal, warm emissive light.

28. Sulfur — rough crusty yellow mineral chunk (RGB 226,206,88), jagged
    crystalline facets.

29. Obsidian Shard — dark blue-black glassy volcanic shard (RGB
    48,44,60), sharp angular facets, glossier/more reflective highlights
    than the other materials.

30. Magma Core — rounded orange-red stone (RGB 244,96,40) glowing from
    within, darker cracked crust patches with bright glow visible through
    the cracks.

31. Lodestone — rough slate-blue-grey magnetized rock chunk (RGB
    96,108,132), a few tiny bits of metal debris stuck to it.

32. Phoenix Ash — small mound of warm orange-grey ash (RGB 255,168,96),
    a few embers still glowing faintly within it.

33. Bag / Inventory icon — simple low-poly canvas satchel bag (base tile
    color RGB 30,118,136), closed with a drawstring or buckle flap, matte
    fabric-brown material, friendly 3/4 angle. Flatter/more graphic
    emblem style than the loot items above — this is a HUD icon.

34. Craft / Anvil icon — small low-poly blacksmith's anvil (base tile
    color RGB 128,88,54), dark iron-grey, chunky faceted shape, classic
    anvil silhouette with horn and flat working face. Flat graphic emblem
    style.

35. Map / Islands icon — rolled or folded low-poly treasure map (base tile
    color RGB 40,120,110), tan/cream parchment, tied with a small cord, a
    hint of a route line or X visible on the fold. Flat graphic emblem
    style.

36. Admin icon — simple low-poly shield emblem (base tile color RGB
    200,70,70), plain shield shape, no symbol on it, dark red/grey matte
    with a slight metallic sheen (it's a badge, not a loot item). Flat
    graphic emblem style.
```

---

## Wiring the result back in

Crop cell N and upload through Studio's Asset Manager to get an
`rbxassetid://`, then paste it into:
1–2 → `Shared/Data/Rods.luau` (`voltline_rod`, `brineheart_rod`)
3–5 → `Shared/Data/Weapons.luau` (`tidebomb_maul`, `voltfang`, `heartrender`)
6–17 → `Shared/Data/Bait.luau` (all 12 rows, in the order listed)
18–32 → `Shared/Data/Materials.luau` (the 15 rows listed, in order)
33–36 → not row-driven — these are hardcoded token strings in
`MenuButtonsController.luau`; swapping them for images is a small code
change (replace `Kit.tile(..., {token = "..."})` with an `Image` id), not
a data edit.

**If per-cell fidelity comes out weak** (36 objects in one canvas is a lot
to ask any model to render sharply), the next-best fallback is 4 separate
one-shot sheets by category — Rods+Weapons (5), Baits (12), Materials (15),
Menu icons (4) — same style guide, same technique, just less crammed per
image.
