# Icon generation prompt (Gemini) — all 72 rod + weapon icons, one sheet

REWRITTEN 2026-08-27, refined same day after the first generation (labels
and the ALL-CAPS emphasis leaked into the art as captions/callouts, and the
background rendered as grey per-cell tiles instead of alpha): every rod
(36) and every weapon (36) as flat vector-style icons on a TRANSPARENT
background, in one 9×8 contact sheet, matched closely to the Blender models.
Supersedes the old 36-cell sheet (which referenced pre-revamp/cut content;
the bait/material/menu cells of that sheet were generated and their icons
remain live — regenerate them in this style later if a uniform look is
wanted).

**Attach both reference renders to the Gemini message** — they are the
fidelity anchor: `assets/rod_preview.png` (36 rods) and
`assets/weapon_preview.png` (36 weapons). Tell Gemini: where the text and
the reference image disagree, FOLLOW THE IMAGE.

**After generating:** slice the 72 cells at even intervals, check each crop
has clean alpha, upload via Studio's Asset Manager, and paste each
`rbxassetid://` into the matching row's `icon` field — cells 1–36 map to
`Rods.order` in `Shared/Data/Rods.luau`, cells 37–72 to the weapons in the
order listed, in `Shared/Data/Weapons.luau`. Replacing the eight existing
low-poly-render icons keeps the whole inventory uniform in the new style.

**If 72 cells come out mushy**, split into two generations — rods (rows
1–4) and weapons (rows 5–8) — with the identical STYLE block.

---

## PASTE THIS WHOLE PROMPT INTO GEMINI (with the two previews attached)

```
Generate ONE single image: a 9×8 contact sheet of 72 equal-sized square cells
in a strict invisible grid, read left-to-right then top-to-bottom, with even
generous empty spacing between cells so they can be auto-cropped at regular
intervals. Each cell contains exactly ONE self-contained object, centered,
filling ~70% of its cell; no two cells may touch or overlap.

ABSOLUTELY NO TEXT OF ANY KIND anywhere in the image: no letters, numbers,
words, captions, labels, subtitles, arrows, leader lines, callouts, or
diagram annotations. The item list below is instructions for YOU only — it
contains capitalized words and parenthetical notes as emphasis, and none of
those words may ever appear rendered in the image. If a description names a
feature, DRAW the feature; never write it. Cell identity comes purely from
grid position, so labels are unnecessary.

BACKGROUND: one single fully TRANSPARENT background (true PNG alpha) across
the entire sheet. No backdrop, no per-cell tiles or panels, no cell shading,
no ground planes, no drop shadows, no vignette — every pixel outside the
objects themselves must be transparent. If transparency is genuinely
unsupported, the only acceptable fallback is one perfectly uniform solid
chroma-green (#00FF00) across the whole sheet with zero per-cell variation,
so it can be keyed out in one pass.

STYLE — identical for all 72 cells: clean flat VECTOR-illustration game
icons. Crisp uniform dark outline (same weight everywhere), flat saturated
color fills with at most two tones per surface (base + one darker shade for
form), no gradients, no photorealism, no texture noise. The objects are
faithful 2D portraits of low-poly 3D models: keep their chunky faceted
silhouettes, straight facet edges, and exact proportions from the two
attached reference renders (a 36-rod lineup and a 36-weapon lineup) — where
these descriptions and the reference images disagree, follow the images.
Rods pose diagonally (butt lower-left, tip upper-right); melee weapons pose
diagonally edge-forward; guns pose in clean side profile, muzzle right.
Anything marked GLOWS gets a bright emissive fill plus a soft outer glow
halo — clearly lit from within, not just a bright flat color.

ROW-BY-ROW CONTENTS (hex colors are exact):

ROW 1 — Starter Cove rods:
1 Twig Rod: crooked driftwood stick #8B6844, twine lashings, wire loop
  guides, classic round bobber (red #D92E29 over white).
2 Bamboo Rod: straight green cane #99AD5C with segment joints, brass
  ferrules+guides #C49A48, slim quill float (orange tip).
3 Angler's Rod: varnished brown blank #8B5527, cork grip, steel spinning
  reel hung below, six guides, bright orange pear float.
4 Reefmaw Rod: stout weathered grey-green blank #6A7566 crusted with
  barnacle cones, shell bands, spinning reel, round cork float.
5 Bonecaster Rod: pale bone shaft #CCC7AD, backswept rib barbs down the
  spine, spiked bone drum reel, GLOWS brine-green #73F28C collars +
  will-o-wisp lantern float.
6 Brineheart Rod: deep red heartwood #693B3D, heavy backswept barbs, spiked
  drum reel, bone hardware #E3D6BF, GLOWS red #FF6168 collars, broad pear
  float.
7 Cinderline Rod: scorched black-brown twig, ember-orange #F08434 cone
  studs, simple wire guides, round float.
8 Obsidian Rod: glassy blue-black blank #30303C with sharp facets, GLOWS
  thin orange heat-crack lines, dark drum reel.
9 Cinderglass Rod: smoky translucent-look amber-grey blank, GLOWS soft
  inner orange, glass collar rings, quill float.

ROW 2 — volcano + Blackmire Fen rods:
10 Magma Core Rod: dark basalt shaft, a glowing #F46028 molten core orb
   swelling mid-blank, GLOWS orange fittings, heavy drum reel.
11 Phoenix Ash Rod: ash-pale shaft warmed to ember #FFA860 toward the tip,
   GLOWS phoenix-orange trim + float, elegant upswept profile.
12 Reedlash: a lashed BUNDLE of green fen reeds #948E5A with cattail seed
   heads poking past the tip, rust bands #A4623E, cork-and-rust float.
13 Gatorback: curved sage blank #5E7448 with a row of broad triangular
   gator SCUTES down its back, armor collar bands, ball float.
14 Wisplight: bog-dark blank #4A4436, a caged LANTERN holding a glowing
   #96EBC8 wisp orb near the tip, GLOWS teal-green trim + bobber.
15 Fenpiercer: rust-iron lance #6E4A34, big flat SPEARHEAD finial at the
   tip, a stack of thin disc fins mid-blank, GLOWS venom-green #B2D25A trim.
16 Mireheart: moss-black living root #3A422E climbed by a jointed thorn-
   vine, ROOT CLAWS gripping the butt, GLOWS wisp-teal #96EBC8 fittings —
   crown piece of the fen.
17 Auger (ice): pale steel-blue shaft #96AABA wrapped in a continuous
   SCREW FLIGHTING ribbon on its lower half (ice drill), small canister,
   quill float.
18 Rimebound: frost-crusted pale blank #B2D0E2 studded with rows of
   discrete hanging ICICLE spikes, frozen collar rings, GLOWS white-blue.

ROW 3 — Frostmaw + Gloomtrench rods:
19 Silverscale: sleek silver blank #C8D4E0 armored in small overlapping
   fish scales lying flat along the shaft like roof shingles, cork grip,
   spinning reel below, pear float.
20 Aurora: blue blank #608CBE hung with stacked BILLOWING translucent
   curtain bands (aurora sheets), GLOWS teal #96E6C8 + pink accents.
21 Frostheart: ice-blade blank wrapped in an open crystal DOUBLE-HELIX
   lattice, big multi-point STARBURST snowflake crown at the tip, GLOWS
   #50DCFF — crown piece of the ice island.
22 Lanternline: near-black shaft #504A60, one big warm caged lantern,
   GLOWS candle-gold #FFE282.
23 Trenchglass: slim dark glassy blank #46546E, GLOWS pale-blue #8CDCFF
   collar rings up its length, quill float.
24 Inkveil: dark violet blank #383048 with curling tentacle barbs, GLOWS
   violet #AA78FF, pear float.
25 Voidline: near-black taut whip blank #282438, minimal hardware, GLOWS a
   thin violet #7850DC line, spiked drum reel.
26 Gloomheart: heavy dark relic rod #3A324E, hooked lure-stalk tip, big
   barbs, GLOWS lantern-gold #FFE282 — crown piece of the gloom island.
27 Ghostplank (wreck): a rod hewn from a squared HULL PLANK #7A8273 with
   visible plank seams, iron straps #99A1A3, BENT NAILS as line guides,
   GLOWS pale spectral-green bobber #A0FFD2.

ROW 4 — Wreckwater + Maelstrom rods:
28 Riggingline: salvaged topmast #73796B with neat rope servings, a working
   BLOCK-AND-TACKLE pulley hanging mid-blank with the line threaded through
   it, ratline double guides, crow's-nest ring at the tip.
29 Doubloon: dark treasure rod #43392F studded with struck gold coin
   bosses, coin-stack reel drum, a CHAIN OF 3 GOLD DOUBLOONS #EFC45A
   dangling from the tip ring, gold float.
30 Sailcloth: raked mast-blank #9CAA9C flying three triangular PENNANT
   SAILS #E0FCEF with luff ropes, cleat-and-halyard at the grip, GLOWS
   soft spectral green.
31 Wraithheart: spectral flagship mast #364240, a GLOWING #8CFFCD ghost-
   fire HEART CAGED in curved ribs at the masthead, flame wisps licking
   the blank, ship's-wheel reel, figurehead bust at the butt — crown piece
   of the wreck island.
32 Squallcaster: storm-bent grey cane #6B7C8C curved hard by wind, thorn
   spurs along it, one small triangular flag streaming sideways off the
   upper blank as if in a gale.
33 Riptide: current-swept blue blank #506E8C, floating diamond storm-panes,
   a prominent LIFE RING hung on it, GLOWS tide-blue #8CC8FF.
34 Thunderhead: charged mast #465064 with stacked flat RING COLLARS
   (cloud discs) and a jagged lightning-scribble finial, GLOWS white
   #DCE6FF.
35 Eyewall: heavy blank #5A6E96 wound in one wide loose CYCLONE RIBBON
   spiral full length, halo ring near tip, GLOWS deep storm-blue #5A82FF.
36 Krakenheart: violet relic #3C2C54 coiled full-length by a sucker-
   studded KRAKEN TENTACLE, lantern float, spiked drum reel, GLOWS violet
   #9678FF — the endgame crown rod.

ROW 5 — fists + cove/fen melee & ranged:
37 Fists: a simple pair of blocky Roblox fists, skin-tan, knuckles forward.
38 Driftwood Club: knotted driftwood club #967048, fat dark head with
   protruding knots, kelp-green wrap #568C54.
39 Scaleblade: quick short blade of pale fish-scale steel #B8D1E6, wooden
   guard+pommel #80603E, bound wooden grip.
40 Shellcrusher: heavy maul — slab of grey-teal barnacle chitin #7D9696 on
   a driftwood haft, crusted claws on the head.
41 Drowncleaver: broad tall cleaver of pale cursed bone #D1CDB6, bone
   handle, GLOWS brine-green #73F28C runes on the blade.
42 Heartrender: long red blade #C44E52, dark heartwood grip, GLOWS a
   beating red #FF6068 heart-line down the blade.
43 Bogwood Bow: recurve bow of steam-bent bogwood #6E5C3A, curved limbs
   with recurved tips, gut string, a nocked ARROW pointing along the shot
   line, moss-cord grip.
44 Rustfang Machete: broad working blade eaten to a ragged rust edge
   #A4623E, bog-oak handle, notched cutting edge.
45 Gatorjaw Crossbow: crossbow with a rifle-like scute-plated stock
   #5E7448, bow-lath spanning near the muzzle swept slightly back, drawn
   string + claw trigger, bone bolt.

ROW 6 — fen/ice weapons:
46 Mire Flintlock: long-barreled flintlock pistol, walnut stock #543E2C,
   brass barrel + lockwork #B2A078, downward-curved grip.
47 Fenreaver: root-bark glaive #3A422E, long swept blade with a GLOWING
   wisp-green #96EBC8 edge, disc guard, barbed back edge.
48 Icepick Hatchet: compact axe #788696 with a broad pale steel bit
   #D2E4F0 and a reversed PICK spike, wrapped haft.
49 Frostbore Long Rifle: bolt-action sniper rifle, full wooden stock
   #686054, pale steel barrel #AABACA, long SCOPE tube on top.
50 Glacier Maul: massive square ice-block head #96C4E0 on a stone-grey
   haft #968C7C, GLOWS pale-blue #78C8FF veins in the head.
51 Frostbite Revolver: revolver, blue-steel frame #5A6474, pale cylinder
   and barrel #C8E0F0, GLOWS frost-blue #78C8FF core line.
52 Rimefang Lance: long lance #8CB4D2, socketed cone tip of pale ever-ice
   #ECF6FC, side barbs, GLOWS ice-blue #50DCFF collar — ice crown weapon.
53 Cinderlock Carbine: military carbine, vent-metal furniture #463838,
   heat-striped orange barrel shroud #F08434, box magazine, carry handle.
54 Obsidian Piercer: driftwood haft #8C6B44 tipped with a wicked glass-
   black obsidian point #302C3C, GLOWS a hairline orange heat crack.

ROW 7 — volcano/gloom weapons:
55 Basalt Scattergun: twin-bore pump shotgun, basalt-grey tubes #3C3E46,
   sulfur-brass fittings #E2CE58, visible side-by-side muzzles.
56 Magma Gauntlets: paired knuckle gauntlets, dark vent-metal #463838,
   sulfur-cured claws #E2CE58, GLOWS a magma vein #F46028 across the fists.
57 Vulkan Repeater: heavy LMG, cooled-obsidian housing #262028, finned
   barrel, top carry handle, DRUM magazine below, GLOWS molten #FF6010
   seams — volcano crown gun.
58 Trenchspike: minimal dark pike #46485C, long square-section spike tip
   #827C8E, utilitarian silhouette.
59 Abyssal Harpooner: speargun — open top rail with a barbed HARPOON
   seated on it, line spool under the rail, twin band lines to a muzzle
   yoke, pistol grip, dark iron #3C4254.
60 Riptide SMG: compact submachine gun #4C5464, boxy receiver, short
   barrel with big front sight, long stick magazine, wire folding stock,
   GLOWS tide-blue #8CDCFF accents.
61 Voidglass Saber: curved near-black glass saber #282438, basket guard,
   GLOWS a violet #AA78FF edge line.
62 Gloomcaller DMR: marksman rifle, dark violet furniture #383248, slim
   TUBE scope, box magazine, GLOWS lantern-gold #FFE282 core — gloom
   crown gun.
63 Boarding Axe: naval axe, worn haft #6E604C, broad steel bit + back
   spike #A0A8B0, rope-wrapped grip.

ROW 8 — Wreckwater/Maelstrom weapons:
64 Grave Blunderbuss: blunderbuss with a wide flaring BELL muzzle, walnut
   stock #685842, weathered steel #969CA4.
65 Phantom Repeater: revolving lever-action carbine, sea-grey wood
   #60746C, visible CYLINDER mid-body, lever loop, GLOWS spectral green
   #A0FFD2 accents.
66 Cutlass of the Fleet: curved naval cutlass #C8D6CE, full basket guard,
   GLOWS a faint spectral-green edge.
67 Admiral's Saber: long officer's saber, gilt guard + fittings #E6BE64,
   sea-grey grip, GLOWS spectral green along the blade — wreck crown blade.
68 Galecleaver: double-headed axe #6E7C8C, both broad heads flared, storm-
   pale edges #C8D6E4.
69 Cyclone Rifle: assault rifle, storm-blue furniture #4C5668, block
   optic on top, box magazine, GLOWS cyan #8CC8FF accents.
70 Thunderhead Cannon: massive-bore hand cannon pistol, white ribbed
   barrel jacket #DCE6FF over dark frame #46505C, GLOWS white-blue.
71 Stormlance: long storm lance #5A6E96, leaf-blade tip #DCE6FF, side
   vanes, GLOWS lightning-blue #8CC8FF collar.
72 Krakenfang: the endgame blade — a curved fang-sword #3C2C54 with a
   sucker-studded tentacle wrapping the grip up onto the blade's back,
   pale bone edge #DCD2F0, GLOWS violet #9678FF.
```
