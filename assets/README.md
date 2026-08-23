# Assets pipeline

## `Assets.rbxm` — the imported meshes, synced by Rojo

Every mesh in this folder (`island_pack.glb`, `rod.glb`, `fish.glb`, `creatures.glb`, `weapon.glb`) has to go
through Studio's **Import** once, because a Roblox MeshPart only references a
mesh id uploaded to Roblox — there is no local path from `.glb` to a working
part. The *result* of those imports is checked in as **`assets/Assets.rbxm`**,
and `default.project.json` maps it to `ReplicatedStorage.Assets`, so on any
machine:

```
git clone …  →  aftman install  →  rojo serve  →  Rojo: Connect  →  Play
```

gives the whole game, meshes included. No saved place file, no manual steps.

**When a mesh changes** (you re-ran one of the `*_gen.py` scripts), the
`.rbxm` is stale and must be re-exported — nothing warns you about this:

1. Import the new `.glb` per the steps below (collision fidelity included —
   that setting is baked into the file).
2. Replace the old model under `ReplicatedStorage/Assets` with it, keeping the
   exact name (`IslandPack` / `RodPack` / `FishPack` / `CreaturePack` / `WeaponPack`).
3. Right-click the **`Assets`** folder → **Save to File…** →
   `assets/Assets.rbxm`, overwriting.
4. Restart `rojo serve` if it was running (it doesn't watch `.rbxm` files
   reliably) and commit the file.

The mesh ids inside the `.rbxm` belong to the account that clicked Import;
they load for that account on any machine, but not for another account
unless the assets are made public or moved to a group.

# Island mesh pipeline

The starter island is authored in Blender, not built from Roblox parts. The
mesh is *generated* — `island_gen.py` is the source of truth, and the island is
never hand-sculpted, so re-running the script reproduces it exactly.

**Export format is glTF (`.glb`), not OBJ.** OBJ was the first thing tried and
it round-trips through Studio's modern Import pipeline as a single merged
MeshPart with no materials at all — every object and colour is lost. glTF
preserves both: the nine pieces (`Island_Base`, `Island_Rocks`, `Palm_Trunks`,
`Palm_Fronds`, `Palm_Coconuts`, `Island_Bushes`, `Dock_Planks`, `Dock_Posts`,
`Island_Foam`) come in as separate, correctly-coloured MeshParts. Confirmed by parsing the
exported `.glb` directly rather than assumed — see the named nodes and
matching `baseColorFactor` values if you want to check it yourself.

The dock is part of the island mesh (`build_dock()` in `island_gen.py`), not
a separate asset: it runs out along Roblox +Z from the beach, and its deck
height is printed by the script as `DOCK_TOP` — `World.DECK_Y` in
`src/Shared/Config/World.luau` must match it.

## Regenerating the mesh

`island_gen.py` is multi-island now: each island is an entry in the `ISLANDS`
config (shape, palette, props) and is selected by argv —
`-- <out.glb> [islandId=tropical] [preview]`. `preview` also writes
`<out>_preview.png`, a headless 3/4 render, so a new island's shape and
palette can be refined from a picture without a Studio import. There's also a
**pack** mode — `-- <out.glb> pack` — that bundles **every** island (each id in
`ISLAND_ORDER`) into one importable `.glb`, the **IslandPack** (see below); this
is what the game actually imports.

```powershell
# THE PACK - every island in one file, the thing you import into Studio
& "$env:LOCALAPPDATA\Programs\blender-4.5.12-windows-x64\blender.exe" `
  --background --python-exit-code 1 --python assets\island_gen.py -- assets\island_pack.glb pack

# a single island + a preview PNG, for refining its shape/palette without importing
& "$env:LOCALAPPDATA\Programs\blender-4.5.12-windows-x64\blender.exe" `
  --background --python-exit-code 1 --python assets\island_gen.py -- assets\island_volcano.glb volcano preview

# the starter island on its own (byte-identical to the original single-island export)
& "$env:LOCALAPPDATA\Programs\blender-4.5.12-windows-x64\blender.exe" `
  --background --python-exit-code 1 --python assets\island_gen.py -- assets\island.glb
```

Edit an island's `ISLANDS` entry (or its prop builders) and re-run. The
script prints the exported object list and tri count (the pack prints a line
per island). **Refine a single island with the `preview` command, then rebuild
the pack** so the change lands in the imported model.

Adding an island: an `ISLANDS` entry (with a unique `model` name) + its id in
`ISLAND_ORDER`, rebuild the pack, re-import, re-export the `.rbxm`, then a row
in `src/Shared/Config/Islands.luau` (the travel menu + placement read it).

- The **tropical** entry reproduces the original starter island exactly
  (same 9 objects `Island_Base` / `Island_Rocks` / `Palm_*` / `Island_Bushes`
  / `Dock_*` / `Island_Foam`, same shape) — leave it byte-identical so the
  starter keeps working.
- **New islands prefix their object names by island id** (e.g. `Volcano_Base`,
  `Volcano_Rocks`, `Volcano_Lava`, `Volcano_Foam`) so they never clash inside
  the pack. Every island keeps the waterline=0 / skirt-bottom=-9 contract so
  `WorldService`'s alignment works for all of them, and each island's objects
  are grouped in the pack under a node named for its **model** (`Island`,
  `Volcano`, …) so `WorldService` can clone one island out at a time.
- **Placement + travel are wired:** `src/Shared/Config/Islands.luau` lists each
  island (model name, world position, radius, spawn, unlock level);
  `WorldService` places every listed island whose group is in the imported pack,
  and the in-game **TRAVEL** menu teleports between them. The Volcano is in the
  pack and in the config but shows "coming soon" in the menu until the pack is
  (re-)imported with its group present.

## Importing into Studio (one-time, and after every regeneration)

The islands are one **IslandPack** — `assets/island_pack.glb`, every island in
a single file, imported once (the same idea as the RodPack / FishPack). Studio's
ribbon button is labelled **Import** (this replaced the old "Import 3D" wizard).

1. **Home** tab → **Import** → pick `assets/island_pack.glb`. This opens the
   **Import Queue** panel at the bottom with the file listed and a green
   checkmark once Studio has validated it.
2. Click the blue **Import** button in the top-right of that panel.
3. A **Model** named `Scene` appears (usually directly under Workspace) with
   one child group **per island** — `Island` and `Volcano` — and inside each,
   the usual `<name>_Node` wrappers around the actual **MeshPart**s. As before,
   a multi-material object splits into numbered primitives: `Island_Base` →
   `Island_Base` / `Island_Base2` / `Island_Base3`, `Palm_Fronds` →
   `Palm_Fronds` / `Palm_Fronds2`, and likewise `Volcano_Base` →
   `Volcano_Base` / `Volcano_Base2` / `Volcano_Base3`. If you only see a single
   merged part named `default`, delete it — that means an `.obj` got imported
   instead of the `.glb`.
4. **Select every actual MeshPart** in the whole import (the leaf items
   *without* `_Node` in the name, across both the `Island` and `Volcano`
   groups), open the **Properties** panel, and set **CollisionFidelity** to
   **PreciseConvexDecomposition**. ⚠️ **Do not skip this** — it is the one thing
   the game code *cannot* set at runtime (it's a plugin-only property). Without
   it you fall **through** the terrain and float above the dome's dips, the rock
   arch fills in solid instead of walkable-under, and the dock planks collide as
   one slab. The quickest way: click the top `Island` group, shift-click the
   bottom `Volcano` group to select everything, then set CollisionFidelity once
   (it applies to all MeshParts in the selection). (Setting it on the
   frond/bush/coconut/foam/lava parts too is harmless — `WorldService` makes
   those non-collidable by name at runtime regardless.)
5. In ReplicatedStorage, create a Folder named **Assets** (if it doesn't
   already exist — it sits alongside the `Shared` folder Rojo syncs, not
   inside it), drag the imported `Scene` model into it, and rename the model
   to exactly **IslandPack**.
6. Re-export `assets/Assets.rbxm` (see the top of this file) and restart
   `rojo serve`.
7. Play. `WorldService` clones each island's group out of the pack, anchors
   everything, disables collision on the fronds/bushes/coconuts/foam/lava by
   name, aligns every island's waterline, and places each at its
   `Islands.luau` world position. (A standalone `Assets/Island` import still
   works as a fallback if the pack isn't present.)

If the model is missing, the game still boots on a plain sand disc and prints
these instructions as a warning in the Output window.

## The rods (rod_gen.py → rod.glb, the RodPack)

**One pack, every rod** — the same "one import" idea as the FishPack. All four
rods (Twig, Bamboo, Angler, Abyssal) are generated side by side into one
`rod.glb`; `RodModel` clones one variant's parts out at runtime. Regenerate
with (add `preview` to also write `assets/rod_preview.png`, the four rods
lined up for review without importing):

```powershell
& "$env:LOCALAPPDATA\Programs\blender-4.5.12-windows-x64\blender.exe" `
  --background --python-exit-code 1 --python assets\rod_gen.py -- assets\rod.glb preview
```

Importing into Studio:

1. **Home** → **Import** → `assets/rod.glb` → blue **Import** button.
2. A model (usually named `Scene`) appears with 24 MeshParts: six per rod,
   named `<Variant>_Twig` / `_Grip` / `_Trim` / `_Line` / `_BobberTop` /
   `_BobberBottom` for each of `Twig`, `Bamboo`, `Angler`, `Abyssal`
   (`_Trim` is the hardware — guides, reel, ferrules, tip ring, pommel
   cap). No collision-fidelity step is needed — rods never collide with
   anything.
3. Drag the model into **ReplicatedStorage/Assets** and rename it to exactly
   **RodPack** (the `model` field on every rod row in
   `src/Shared/Data/Rods.luau`). **Delete the old `TwigRod` model** — it's
   replaced by the pack.
4. Re-export `assets/Assets.rbxm` (see the top of this file) and restart
   `rojo serve`.
5. Play. `RodModel` clones the equipped rod's variant parts (renamed to the
   generic `Rod_*`), recolours every part per the rod row's `model.colors`
   (marking the parts in `model.neon` as glowing), and `RodService` welds it
   into the hand.

What each variant is (all knobs in `VARIANTS` / `FLOATS` at the top of the
script — shaft taper, curve and `hook`, `flatten` for a blade-like
cross-section, grip style, `bands`, `guides`, `tip_ring`, `reel`, `pommel`,
the idle `line`, and which `float` profile hangs off it):

- **Twig** — a crooked driftwood stick with grown twigs, cord grip, two
  twine-lashed wire-loop guides, the classic round red/white bobber.
- **Bamboo** — a straight cane with brass ferrules at the joints, brass
  wire guides and tip ring, a capped butt, a slim orange-tipped quill float.
- **Angler** — a proper rod: varnished fast-taper blank, cork handle with a
  steel reel seat and a **spinning reel** hung under it, six snake guides,
  a tip ring, a pear float on a stem.
- **Abyssal** — a flattened black-iron blade that **hooks forward** at the
  tip, backswept barbs, glowing teal collars and tip ring, a spiked iron
  drum reel, a pommel spike, and an anglerfish **lantern** lure (glowing
  orb over an iron cage with three barbs). The glow comes from
  `model.neon = { "Rod_Trim", "Rod_BobberTop" }` on its row.

If `RodPack` is missing, every rod falls back to a plain-cylinder stand-in in
the hand and prints these instructions as a warning.

Authoring contract (rod_gen.py ↔ RodModel):

- Every variant stands along +Y: butt at y = 0, tip at y = `ROD_LENGTH` (7).
  All variants share `ROD_LENGTH` and `GRIP_CENTER` so one `grip`/`length`
  pair in `Rods.luau` covers them all.
- `<Variant>_Grip` must be its own object — its centre is the hand point.
  `GRIP_CENTER` (0.95) must match the `grip` field in `Rods.luau`.
- Variants overlap at the origin in the pack (invisible in the template);
  they're only spread out for the preview render. Runtime placement is
  grip-relative, so the overlap doesn't matter.
- Colours in `rod_gen.py` are preview-only; the game colour is per rod row
  (`model.colors` keys `twig` / `grip` / `trim` / `line` / `bobberTop` /
  `bobberBottom`, any missing key falling back to `RodModel`'s defaults).
  `_Trim` is optional — `RodModel` skips a variant that has none.
- The float is split at its waterline into `_BobberTop` / `_BobberBottom`
  so the two halves take two colours; hardware lives on Blender −y (the
  rod's underside in the first-person hold, after the importer's 180° flip).

## The fish (fish_gen.py → fish.glb, the FishPack)

Every species is a parameter set in `SPECIES` at the top of `fish_gen.py`
— body profile, tail style (`forked` / `rounded` / `square` / `lunate`),
dorsal and anal fin list (`soft` / `spiny` / `sickle` / `adipose`),
pectoral length, finlets, barbels, jaw, side markings (`stripe` / `bars`)
— all built by the same code, and **all exported into the one `fish.glb`**
side by side, so there's a single Studio import no matter how many species
there are. `CreatureModel.luau` picks a species out of the pack by part-name
prefix. Sixteen species today: Perch, Mackerel, Trout, Bass, Cod, Catfish,
Salmon, Tuna, plus the **Puffer** — the pufferfish, which has its own
`build_puffer` (a faceted ellipsoid + cone spikes + big eyes + a beak,
`custom="puffer"` in `SPECIES`) instead of the shared profile-and-fins
code, but exports the same `Puffer_Body/_Fins/_Eyes/_Marks` so it's imported
and picked like any other species. Its creature row also keeps
`shape = "puffer"` as a parts fallback shown before the pack is imported.
Regenerate (and render a side-view line-up to check the shapes without
importing) with:

```powershell
& "$env:LOCALAPPDATA\Programs\blender-4.5.12-windows-x64\blender.exe" `
  --background --python-exit-code 1 --python assets\fish_gen.py -- assets\fish.glb assets\fish_preview.png
```

The second path is optional; `fish_preview.png` is a Workbench render of
every species from the side.

Importing into Studio:

1. **Home** → **Import** → `assets/fish.glb` → blue **Import** button.
2. A model (usually named `Scene`) appears with a node per mesh —
   `Perch_Body_Node`, `Perch_Fins_Node`, `Perch_Eyes_Node`,
   `Perch_Marks_Node`, then the same for each species (Catfish has no
   `_Marks`; Tuna's `_Marks` is its finlets; the Puffer's is its beak).
   ~35 MeshParts. No collision-fidelity step — creatures never collide
   with anything.
3. Drag the model into **ReplicatedStorage/Assets** and rename it to
   exactly **FishPack** (the `body.model` field on every row in
   `src/Shared/Data/Creatures.luau`). Delete the old single `Fish` model if
   it's still there — nothing uses it.
4. Re-export `assets/Assets.rbxm` (top of this file).
5. Play, cast, finish the reel. `CreatureService` builds the row's species
   out of the pack, recolours body / fins / marks from the row, scales it,
   and throws it at you.

If the pack is missing, or a row names a species the pack doesn't have, the
game still runs with an elongated-ball stand-in and prints these
instructions as a warning.

Adding a species: a dict in `SPECIES` + its name in `ORDER`, re-run, re-import
the pack, re-export the `.rbxm`, then a row in `Creatures.luau` with
`species = "<Name>"`. Recolour-only variants of an existing shape (a
"golden perch") are just a row.

The seven **volcano fish** (2026-08-23) are dedicated species, not recolours:
`Emberfin`, `Ashgill`, `MagmaGuppy`, `ObsidianBass`, `BasaltCod`, `PyreSalmon`,
`MagmafinTuna` — each with its own lava shape (spiny ember crests, faceted
obsidian bodies, molten finlets). Their `Creatures.luau` rows are the
`waters = "volcano"` fish and already point at these species.

Authoring contract (fish_gen.py ↔ CreatureModel):

- Every species is `BODY_LENGTH` (2 studs) nose to tail before a row's
  `scale`, body centred on its own origin (the preview spacing along X is
  irrelevant at runtime — parts are placed relative to the body).
  `CreatureModel.BASE_LENGTH` must match.
- **Length > height > width** for every species: `CreatureService` lays a
  fish flat by reading its bounding box's longest and shortest axes.
- Objects `<Species>_Body` / `_Fins` / `_Eyes` and optionally `_Marks`;
  `CreatureModel` clones them out and renames them `Fish_Body` /
  `Fish_Fins` / `Fish_Eyes` / `Fish_Marks`, which is what everything
  downstream (physics, hit feedback, VFX) looks for.

## The hostile creatures (creatures_gen.py → creatures.glb, the CreaturePack)

The non-fish enemies are a *second* creature pack, same idea as the FishPack
(the two are separate models; the FishPack is fish only). Twenty species:
**Snapjaw Crab**, **Drowned Deckhand**, **Drowned Angler**, the eight
from the enemies slice — **Tideline Skipper** (mudskipper on stilt legs),
**Gullet Cod** (gaping maw, teeth, throat), **Tidebomb Urchin** (spiny ball
with ember warts), **Moonbell Jelly** (faceted bell, oral arms, tendrils),
**Sand Lurker** (flounder with a fin fringe and stalk eyes), **Pearl Mimic**
(fluted clam, pearl inside), **Pickpocket Hermit** (crab in a coin-filled
pot), **Voltray** (kite ray with electric organs and a whip tail) — the
island boss **Brinejaw**, and the volcano roster (2026-08-23):
**Fumarole** (a blistered vent mound with a molten throat), **Ember Swarm**
(a cloud of cinders round a hot heart), **Magma Ooze** (a slumped blob
pre-cracked along the seams it splits on), **Obsidian Shardback** (a crab
behind a wall of forward-jutting glass), **Cinder Djinn** (a legless smoke
wraith with an ember core), **Lodestone Eel** (a banded magnetite serpent),
**Slagheart Golem** (slag plates caging a molten heart), **Ashfeather
Phoenix** (a bird mid-dive with fire in its plumage).

Three of the volcano meshes are doing *mechanical* work, not decoration, so
keep their shapes if you rebuild them: the Shardback's shards face FORWARD
(it is armoured from the front and soft behind — built as wedges, because an
`xz` plate is edge-on from the one angle the player fights it), the Golem's
core sits in a deliberate GAP in its chest plating (the crack-open window has
to have something to light), and the Phoenix's fire is a separate `_Marks`
layer (so a rebirth can flare without recolouring the bird).

**The volcano palette is a family rule, not per-creature taste** (2026-08-23):
near-black basalt bodies with a small amount of *saturated* molten orange in
the `_Marks`, which is what makes them read as rock with lava inside. Two
deliberate exceptions carry the variety — the Magma Guppy is simply molten all
over, and the Lodestone Eel glows cool blue-white because it is magnetite, not
lava. Mid-tone orange bodies were tried first and read as muddy brown; and in
the *preview only*, volcano `_Marks` emit at 0.65 rather than 1.2, because a
saturated orange at full strength clips to yellow-white and every molten thing
came out looking gold. The game's own colours live in `Creatures.luau`; the
`COLORS` table here mirrors them so the preview is an honest picture. Every
creature is built from the helpers at the top of the script — `revolve`
(bodies / bells / pots), `plate` (fins, wings, shell plates), `chain`
(legs, tendrils), `fluted_dome` (clam valves), `limb` / `cone` /
`ellipsoid` — and each builder's comment states its bounding-box ordering;
the script prints every creature's bbox with an OK / BAD verdict on each
run so the orientation rules can be checked without Studio. **Treat a BAD as a
build failure, not a warning** — a flat creature that fails `x > y > z` lies on
its side in game. Regenerate with (add `preview` to also write
`assets/creatures_preview.png`, a 5-wide grid with the newest in front):

```powershell
& "$env:LOCALAPPDATA\Programs\blender-4.5.12-windows-x64\blender.exe" `
  --background --python-exit-code 1 --python assets\creatures_gen.py -- assets\creatures.glb preview
```

To judge a few closely, add `only=Name,Name` — twenty in one grid is far too
small to tell whether a fin reads. It renders to `creatures_preview_subset.png`
and deliberately writes **no** `.glb`, so a partial build can never overwrite
the pack. `fish_gen.py` takes the same flag (`only=PyreSalmon,...` →
`fish_preview_subset.png`):

```powershell
& "$env:LOCALAPPDATA\Programs\blender-4.5.12-windows-x64\blender.exe" `
  --background --python assets\creatures_gen.py -- assets\creatures.glb preview only=SlagGolem,Phoenix
```

Importing into Studio:

1. **Home** → **Import** → `assets/creatures.glb` → blue **Import** button.
2. A model appears with 80 MeshParts — four per creature, named
   `<Name>_Body` / `_Fins` / `_Eyes` / `_Marks` for `Crab`, `Deckhand`,
   `Angler`, `Skipper`, `GulletCod`, `Urchin`, `Jelly`, `Lurker`, `Mimic`,
   `Hermit`, `Voltray`, `Leviathan`, `Fumarole`, `EmberSwarm`, `MagmaOoze`,
   `Shardback`, `CinderDjinn`, `LodestoneEel`, `SlagGolem`, `Phoenix`. No
   collision-fidelity step. If a creature spawns as a plain parts stand-in
   that's the pre-import fallback (`CreatureModel` `shape`) — which is why
   those `shape` fields stay in `Creatures.luau` permanently: they keep a
   fresh clone playable without a Studio round-trip.
3. Drag the model into **ReplicatedStorage/Assets** and rename it to exactly
   **CreaturePack** (the `model` field on those rows in
   `src/Shared/Data/Creatures.luau`), **replacing** any earlier CreaturePack.
   The FishPack stays alongside it.
4. Re-export `assets/Assets.rbxm` (see the top of this file — the folder now
   holds Island, RodPack, FishPack **and** CreaturePack) and restart
   `rojo serve`.
5. Play (or use the admin `P` → Spawn Creature menu). `CreatureModel` picks
   each creature's parts, recolours `Body`/`Fins`/`Eyes`/`Marks` from the row
   (`color` / `finColor` / eye default / `markColor` — the Angler's `markColor`
   is its glowing lure), and spawns it.

Authoring contract (creatures_gen.py ↔ CreatureService):

- Blender +X → Roblox +X = the way the creature FACES/charges; Blender +Z →
  Roblox +Y = up.
- Flat creatures (crab, skipper, cod, urchin, lurker, hermit, ray): authored
  so front-to-back (+X) is the single longest axis, height the shortest.
- Upright creatures (the zombies, the jelly, the mimic): authored Z-up, rows
  carry `body.stance = "upright"` so CreatureService stands them; they face
  +X.
- The Mimic's lid must be its `_Fins` object: `CreatureService` hinges that
  part 0.9 behind the shell's centre on the facing axis, raising the +X
  edge. Keep the lower valve centred on x=0.
- The Voltray's `_Marks` are its electric organs and the Jelly's its glowing
  core — the client renders `_Marks` as Neon while those creatures charge /
  always, so keep the glowing bits in that group.
- `Body` is mandatory (becomes `Fish_Body` → PrimaryPart + throw weld).

### The island boss (Leviathan)

`creatures_gen.py` also builds **`Leviathan`** — Brinejaw, the Starter Cove
boss (`src/Shared/Data/Bosses.luau`) — as a twelfth species in the same
`creatures.glb`: an upright (stance) anglerfish-leviathan ~17 studs long,
~7.6 tall to the sail tip (`report_bbox` prints it as "upright (stance)").
Same four objects (`Leviathan_Body/_Fins/_Eyes/_Marks`); its `_Marks` are
the lure bulb, gill slits and throat, which the game makes Neon when it
enrages. It sits in the back row of `creatures_preview.png`. Nothing extra
to do at import — it comes in with the pack; until the pack is re-imported
the game shows `CreatureModel.buildLeviathan`'s parts stand-in instead.

## The water (water_gen.py → water.png)

The ocean is still one flat part. The stylised look is a flat blue plane
with one seamless tiling "caustics" texture — wavy cell-edge lines,
transparent everywhere else — laid on the top face; the motion is the client
scrolling it slowly (`OceanController`). The lines are white in the file and
tinted/faded from `Ocean.LAYERS` (`color`, `transparency`), so the look can
be tuned without re-uploading. Same Blender pipeline, but the output is a
PNG, not a mesh. Regenerate with:

```powershell
& "$env:LOCALAPPDATA\Programs\blender-4.5.12-windows-x64\blender.exe" `
  --background --python-exit-code 1 --python assets\water_gen.py -- assets\water.png
```

Knobs at the top of the script: `CELLS` (cells per tile — fewer is lazier),
`LINE_WIDTH` / `LINE_SOFTNESS`, `WARP` (how much the lines bend), and
`LINE_COLOR`. The water's blue itself is `Ocean.COLOR` in
`src/Shared/Config/Ocean.luau`, not in the texture.

The **white rim along the sand** is not part of this texture — it's
geometry in the island mesh (`build_foam()` in `island_gen.py`, object
`Island_Foam`), so it follows the real coastline.

Importing into Studio (one-time, and after every regeneration):

1. Rojo cannot sync images, so this is uploaded as an asset. **View** →
   **Asset Manager** → click **Import** (the folder-with-arrow icon), pick
   `assets/water.png`, and confirm. It lands under **Images** once
   moderation passes (usually seconds).
2. Right-click the image in the Asset Manager → **Copy Asset ID** (a bare
   number, not a URL).
3. Paste the number into `Ocean.TEXTURE_ID` in
   `src/Shared/Config/Ocean.luau`.
4. Play. `WorldService` lays it as one `Texture` per entry in
   `Ocean.LAYERS`; `OceanController` scrolls them.

While the id is still 0 the ocean is a bare blue plane and `WorldService`
warns with these steps.

Authoring contract (water_gen.py ↔ Ocean.luau):

- The tile wraps seamlessly in U and V by construction (periodic Voronoi
  lattice, wrap-around distances, whole-cycle warp frequencies).
- Each `Ocean.LAYERS` entry's `tileStuds` sets how many studs one copy of the
  tile covers, so a cell is roughly `tileStuds / CELLS` studs across.

## The lava (lava_gen.py → lava.png)

The volcano's crater lava gets a stylised "yellow lava" texture — bright molten
plates broken up by orange crack veins, the same periodic domain-warped Voronoi
pipeline as the water but **opaque and coloured**. Regenerate with:

```powershell
& "$env:LOCALAPPDATA\Programs\blender-4.5.12-windows-x64\blender.exe" `
  --background --python-exit-code 1 --python assets\lava_gen.py -- assets\lava.png
```

Knobs at the top of the script: `CELLS` (plates per axis — fewer = chunkier),
`VEIN_WIDTH` / `VEIN_SOFTNESS` (the orange cracks), `WARP` (how organic the
plates bend), and the `YELLOW` / `ORANGE` / `CORE` colours.

Importing into Studio (one-time, and after every regeneration):

1. Rojo can't sync images, so upload it: **View → Asset Manager → Import**, pick
   `assets/lava.png`, confirm; it lands under **Images**.
2. Right-click it → **Copy Asset ID** (a bare number).
3. Paste it into `Lava.TEXTURE_ID` in `src/Shared/Config/Lava.luau`.
4. Play. The client `LavaController` builds a **MaterialVariant** from it and
   tiles it across every `*Lava` part — no UVs, no mesh re-import — then adds
   the bubbles/bursts/shimmer on top.

While the id is still 0 the lava falls back to a flat bright molten colour
(`Lava.FALLBACK_COLOR`, Neon) so it never reads dark.

Authoring contract (lava_gen.py ↔ Lava.luau / LavaController):

- The tile wraps seamlessly in U and V (same construction as the water tile),
  so the MaterialVariant tiles it across the lava with no seams.
- `Lava.STUDS_PER_TILE` sets how many studs one copy of the tile covers, so a
  plate is roughly `STUDS_PER_TILE / CELLS` studs across.
- Applied by studs via the MaterialVariant, so the lava mesh needs no UVs and
  the pack does not have to be re-imported for a lava-texture change.

## The cast animation (rod_cast_anim.py → RodCastAnim.luau + rod_cast.blend)

The first-person cast swing is keyframed in Blender and exported as
**numbers, not a Roblox Animation asset** — the viewmodel is code-posed
(no rig, no Motor6Ds), so there is nothing for an Animator to drive, and a
data module stays in the repo with no upload / asset-id step. Regenerate
with:

```powershell
& "$env:LOCALAPPDATA\Programs\blender-4.5.12-windows-x64\blender.exe" `
  --background --python-exit-code 1 --python assets\rod_cast_anim.py -- src\Shared\Data\RodCastAnim.luau
```

This writes two things:

- `src/Shared/Data/RodCastAnim.luau` — the clip, sampled every frame at
  30 fps as `{ x, y, z, qx, qy, qz, qw }` CFrame argument lists, plus
  `RELEASE_TIME` (when the bobber leaves the tip). **Generated — don't
  hand-edit.** Rojo syncs it like any other module; there is no Studio
  import step.
- `assets/rod_cast.blend` — a preview scene with the real rod mesh hung off
  the animated pivot and a camera at the player's eye. Open it, look
  through the camera (numpad 0) and press Space to watch the swing.

To change the motion, edit the `KEYS` table at the top of the script — one
row per keyframe: time, rotation about the elbow (degrees, X tips the rod
back/forward, Z swings it sideways), and a small translation — and re-run.
The `.blend` is a *preview*, not the source: keyframes tweaked there by hand
are overwritten on the next run.

Authoring contract (rod_cast_anim.py ↔ RodViewmodelController):

- Axes are the camera's: Roblox +X right, +Y up, −Z forward. Blender +Y is
  forward (Blender y → Roblox −z). The conversion is done by the script
  itself — the numbers never go through Studio's glTF importer, so the
  importer's 180° flip noted for the meshes does not apply here.
- Frame 0 is the identity (idle). The **last frame is held** for as long as
  the cast is out — it's the "line's in the water" pose — and the game eases
  back to idle itself when the cast ends.
- The transform moves the whole viewmodel (rod + hand + forearm) about the
  elbow. The game finds the elbow from the character's actual arm parts;
  the preview scene only approximates it.
- `RELEASE_TIME` should land on the fastest forward point of the whip.

## The punches (fist_punch_anim.py → FistPunchAnim.luau + fist_punch.blend)

Same idea as the cast: keyframed in Blender, exported as numbers, played by
`FistsViewmodelController`. Regenerate with:

```powershell
& "$env:LOCALAPPDATA\Programs\blender-4.5.12-windows-x64\blender.exe" `
  --background --python-exit-code 1 --python assets\fist_punch_anim.py -- src\Shared\Data\FistPunchAnim.luau
```

- `src/Shared/Data/FistPunchAnim.luau` — two clips, `jab` (left leads) and
  `cross` (right leads), each with a **track per fist**: the leading fist
  punches while the other tightens the guard. **Generated — don't
  hand-edit.**
- `assets/fist_punch.blend` — preview of the jab with block arms at the
  in-game guard and a camera at the player's eye.

Only the jab is keyframed (`JAB` at the top of the script); the cross is
the jab **mirrored across the centre of the screen** at export, so the two
are exactly symmetrical and there's one set of keys to tune. Successive
punches cycle `SEQUENCE` (`jab`, `cross`).

Authoring contract (fist_punch_anim.py ↔ FistsViewmodelController):

- Each track is a transform about **that fist itself** (the hand's
  centre), camera axes as for the cast — so a key's location is literally
  where the fist goes on screen, and its rotation only swings the forearm
  trailing behind. Both tracks start and end at the identity (the guard)
  so a finished punch needs no blend back; an interrupted one is blended
  by the Lua side (`PUNCH_BLEND`).
- `HIT_TIME` is full extension — where the hit check goes once combat
  exists.
- The preview's guard pose mirrors `FIST_POSITION` / `FOREARM_DIRECTION`
  and the block sizes from the Lua side; keep them in step when tuning.

## The weapons (weapon_gen.py → weapon.glb, the WeaponPack)

Every crafted weapon is a Blender mesh in the shared **WeaponPack**, the same
one-import idea as the RodPack: **DriftwoodClub**, **Scaleblade**,
**Shellcrusher** (barnacle maul) and **Drowncleaver** (cursed-bone cleaver).
`src/Shared/Modules/WeaponModel.luau` still carries the old **procedural**
`club`/`blade` builders (keyed by a row's `model.shape`) as the **pre-import
fallback** — a weapon is never invisible before the pack is imported.
Regenerate with (add `preview` to also write `weapon_preview.png`):

```powershell
& "$env:LOCALAPPDATA\Programs\blender-4.5.12-windows-x64\blender.exe" `
  --background --python-exit-code 1 --python assets\weapon_gen.py -- assets\weapon.glb preview
```

Importing into Studio:

1. **Home** → **Import** → `assets/weapon.glb` → blue **Import** button.
2. A model appears with MeshParts named `<Variant>_Haft` / `_Grip` / `_Head` /
   `_Edge` / `_Guard` / `_Spike` / `_Glow` for `DriftwoodClub`, `Scaleblade`,
   `Shellcrusher` and `Drowncleaver` (only the parts each uses). No collision
   step. If a weapon shows as a plain club/blade that's the pre-import fallback
   (its row's `model.shape`).
3. Drag the model into **ReplicatedStorage/Assets** and rename it to exactly
   **WeaponPack** (`model.model` on those rows). The other packs stay alongside.
4. Re-export `assets/Assets.rbxm` (see the top of this file) and restart
   `rojo serve`.
5. Craft one (the `C` menu) and equip. `WeaponModel.assembleVariant` pulls the
   variant's parts, renames them to the generic `Weapon_*` set, and recolours
   by the row's `color` / `accent` / `wrap` / `glow` (the Drowncleaver's `glow`
   runes are Neon; listed in `model.neon`).

Authoring contract (weapon_gen.py ↔ WeaponModel / WeaponViewmodelController):

- 1 Blender unit = 1 stud. Exported Y-up (Blender +Z → Roblox +Y): the weapon
  stands butt at z=0, tip at z=`length`.
- `_Grip` is its own object and its **centre is the hand point** (z=`grip`);
  the viewmodel hangs the swing-trail attachments off its local frame, so the
  grip's frame must be the weapon frame. `length`/`grip` must match the row.
- `_Grip` is required (becomes `Weapon_Grip` → PrimaryPart); every other part
  is optional per variant.

## The weapon swings (weapon_swing_anim.py → WeaponSwingAnim.luau + weapon_swing.blend)

The weapons' swing animation is generated — the
same Blender-keyframes-to-numbers pipeline as the cast and the punches,
played by `WeaponViewmodelController`. Regenerate with:

```powershell
& "$env:LOCALAPPDATA\Programs\blender-4.5.12-windows-x64\blender.exe" `
  --background --python-exit-code 1 --python assets\weapon_swing_anim.py -- src\Shared\Data\WeaponSwingAnim.luau
```

- `src/Shared/Data/WeaponSwingAnim.luau` — one clip per entry in the
  script's `CLIPS` table, keyed by the name a weapon row puts in its
  `swing` field (`chop` for the club, `slash` for the blade), each with
  `DURATION`, `HIT_TIME` and the sampled frames. **Generated — don't
  hand-edit.**
- `assets/weapon_swing.blend` — preview of the **last** clip in `CLIPS`
  (the chop): a stand-in club + block arm at the in-game hold, camera at the
  player's eye. Numpad 0, Space.

Authoring contract (weapon_swing_anim.py ↔ WeaponViewmodelController):

- A clip is a transform of the **whole weapon viewmodel** (weapon + hand +
  forearm) about a pivot at the elbow — the cast's contract, so the same
  `Rig:pin` path plays it. Camera axes as for the cast (the script converts;
  nothing passes through the glTF importer).
- **First and last frames are the identity** (the idle hold), so a finished
  swing needs no blend back; an interrupted one is blended by the Lua side
  (`SWING_BLEND`).
- `HIT_TIME` is the bottom of the arc — when `CombatController` asks the
  server to land the hit. A weapon row's `cooldown` should be at least
  that long.
- The preview's hold pose mirrors `GRIP_POSITION` / `WEAPON_PITCH` /
  `WEAPON_YAW` / `FOREARM_DIRECTION` from the Lua side; keep them in step.
  Adding a weapon with a new swing: a new `CLIPS` entry here, re-run, then
  `swing = "<name>"` on its row.

## Authoring contract (island_gen.py ↔ WorldService)

- 1 Blender unit = 1 stud; exported Y-up (`export_yup=True` converts from
  Blender's native Z-up).
- Waterline at y = 0; dry sand ~0.7–2.5; grass plateau ~4–7.
- The underwater skirt bottoms out at **exactly −9**. That bottom face is what
  `WorldService` aligns on, so the model can sit anywhere in the file and still
  land with its waterline matching the ocean plane.
- Object names matter: `Palm_Fronds`, `Island_Bushes`, `Palm_Coconuts`,
  `Island_Foam` are made non-collidable by name at runtime.
- `Island_Foam` is a paper-thin closed slab at z = 0.16 (just above the
  waterline) following `ring_radius(1.0, θ)`, inset `FOAM_INSET` under the
  sand so there is no seam. Foam collars around dock posts are only added
  where the sand under the post is below water. glTF preserves these as the actual
  MeshPart names in Studio, which is what that name-matching relies on.
