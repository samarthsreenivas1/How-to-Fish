# Item icons

18 low-poly inventory icons (rods, weapons, materials), cropped from the
Gemini-generated icon sheet (`assets/Gemini_Generated_Image_*.jpg`) to match the
game's Blender models. Each is a ~427px PNG named by its item id.

## They must be uploaded to Roblox before they show

Roblox can't display a local PNG at runtime — an `ImageLabel.Image` only takes an
`rbxassetid://...`. So these files can't be referenced directly; each has to be
uploaded once, exactly like `water.png` → `Ocean.TEXTURE_ID`.

1. In Studio: **Asset Manager** → **Bulk Import** (or drag) → select every PNG in
   this folder. Studio uploads them and assigns each an asset id.
2. For each uploaded image, copy its id and paste it into the matching row's
   `icon` field as `icon = "rbxassetid://<id>"`. The inventory UI
   (`InventoryController`) already renders `row.icon`; `""` shows the blank
   placeholder until an id is in place.

## Which file has each `icon` field

| PNG | item id | row lives in |
|-----|---------|--------------|
| twig_rod.png | twig_rod | `Shared/Data/Rods.luau` |
| bamboo_rod.png | bamboo_rod | `Shared/Data/Rods.luau` |
| anglers_rod.png | anglers_rod | `Shared/Data/Rods.luau` |
| abyssal_rod.png | abyssal_rod | `Shared/Data/Rods.luau` |
| reefmaw_rod.png | reefmaw_rod | `Shared/Data/Rods.luau` |
| bonecaster_rod.png | bonecaster_rod | `Shared/Data/Rods.luau` |
| fists.png | fists | `Shared/Data/Weapons.luau` |
| driftwood_club.png | driftwood_club | `Shared/Data/Weapons.luau` |
| scale_blade.png | scale_blade | `Shared/Data/Weapons.luau` |
| shellcrusher.png | shellcrusher | `Shared/Data/Weapons.luau` |
| drowncleaver.png | drowncleaver | `Shared/Data/Weapons.luau` |
| driftwood.png | driftwood | `Shared/Data/Materials.luau` |
| kelp_fiber.png | kelp_fiber | `Shared/Data/Materials.luau` |
| fish_scale.png | fish_scale | `Shared/Data/Materials.luau` |
| pearl.png | pearl | `Shared/Data/Materials.luau` |
| barnacle_chitin.png | barnacle_chitin | `Shared/Data/Materials.luau` |
| cursed_bone.png | cursed_bone | `Shared/Data/Materials.luau` |

`barnacle_single.png` is a spare — the sheet had two barnacle icons, and
`barnacle_chitin.png` (the chunky plate pile) is the one wired to the material.
Delete the spare if you don't want it.
