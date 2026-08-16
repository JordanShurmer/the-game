# Research: How Noita Generates Biomes

This document records how Noita builds its world. It is the base for
our plan in `plan.md`. Sources are listed at the end. Facts we could
not verify directly are marked "(inferred)".

## The big picture

Noita builds the world in layers:

1. A **biome map** says which biome owns each region of the world.
2. Each biome fills its regions with terrain. Most biomes use
   **herringbone wang tiles**: hand-painted PNG tiles that the
   generator stitches together without visible seams.
3. Colors inside the tile PNGs encode **materials** and **spawn
   points**. Artists paint the world; the engine reads the paint.
4. **Pixel scenes** stamp hand-crafted set pieces on top: some at
   random anchor points, some at fixed world coordinates.
5. Some biomes skip tiles and run **fully procedural** code
   (noise caves, sky, lakes).

The same falling-sand engine then simulates every placed pixel.

## The engine substrate

From the GDC 2019 talk "Exploring the Tech and Design of Noita"
(Petri Purho):

- The world is one continuous pixel grid, split into **512x512 pixel
  chunks**. Chunks stream in and out around the player.
- Generation must therefore work **per chunk, on demand, in any
  order**. A chunk cannot depend on a neighbor that does not exist yet.
- The simulation updates only **dirty rects** inside chunks, and
  multithreads with a checkerboard scheme (64x64 regions in 4 passes)
  so threads never touch adjacent pixels at once.

The lesson for us: world generation and simulation share the chunk
grid, and generation must be deterministic from (seed, chunk position).

## The biome map

- The map is a small PNG (`data/biome_impl/biome_map.png`). **Each
  pixel of the map is one 512x512 pixel region of the world.** The
  main world is 35,840 pixels wide, which is 70 map pixels.
- Each pixel color is a key. The engine matches the color (for
  example `ffd57917`) to a `<Biome>` entry, which names the biome
  config file to load.
- The biome config names the **wang tileset PNG** and sets biome
  parameters (fill materials, background, music, spawn scripts).

So the whole world layout is one small image an artist can edit.

## Herringbone wang tiles

Noita uses Sean Barrett's `stb_herringbone_wang_tile` scheme.
Verified details from the stb source:

- Tiles are **2:1 rectangles** in two orientations: horizontal
  (2n x n) and vertical (n x 2n), where n is the short side length.
- Tiles are laid in a **herringbone pattern**, not a square grid.
  In a square grid, seams line up into long straight lines and the
  eye catches them. In herringbone, no long seam line exists.
- Each tile edge carries a **constraint color**. Edge mode uses 6
  edge classes (a-f); corner mode uses 4 corner classes. Each class
  allows 1-8 colors. Two tiles may touch only where their edge
  colors match. This is what makes tile borders connect: an artist
  draws a cave opening on every edge of color 1, and the generator
  only joins edges of equal color, so caves always continue.
- A **template image** enumerates every valid combination of
  constraint colors, with metadata encoded in the first pixel row.
  The artist paints terrain into each slot of the template. The
  generator cuts the template back into tiles at load time.
- Generation: assign constraint colors across the plane (randomly),
  then for each herringbone cell pick a random tile whose edge
  colors match. Corner mode also runs a repetition-reduction pass.

Because the template enumerates all combinations, a fully painted
template guarantees a matching tile always exists.

## Paint semantics inside a tile

Colors in a tile PNG mean things:

- **Shades of gray** are placeholders. The biome config maps them to
  real materials. One tileset can serve many biomes as a re-skin.
- **Other colors** place a specific material directly. Each material
  has a `wang_color` (hex ARGB) in `materials.xml`.
- **Special marker colors** call spawn functions. Example: a pixel
  of `ffffd171` calls `spawn_orb(x, y)` at that world position. The
  color-to-function table lives in `data/scripts/wang_scripts.csv`,
  and the functions live in the biome's Lua script (spawn enemies,
  chests, props, lamps, wands).
- Transparent pixels are air.

This is the key workflow idea: **the level format is an image**, so
any pixel editor is a level editor. Nolla did not ship a custom map
editor; they painted tiles in ordinary image tools. (inferred from
the modding workflow, which uses plain PNG files)

## Pixel scenes

- Pixel scenes are hand-crafted PNG structures stamped after wang
  tile terrain: buildings, altars, vaults, story set pieces.
- Biome configs place some at random with per-scene probabilities.
  Global scenes (`data/biome/_pixel_scenes.xml`) use absolute world
  coordinates for story-critical structures.
- Scenes use the same color-to-material and spawn-marker semantics
  as tiles. Some carry a separate background image layer.

## Fully procedural biomes

Some Noita biomes do not use wang tiles. Their configs run
procedural algorithms (noise caves, the sky islands, fungal growth).
Biome Lua scripts can also modulate spawns and materials by depth.
So the architecture allows **one generator interface with several
implementations**: wang tiles is the main one, noise is another.

## What we take from this

1. Chunked world; generation is deterministic per chunk.
2. A tiny biome-map image controls world layout.
3. Herringbone wang tiles for authored-but-varied terrain.
4. Color-coded PNGs as the authoring format: materials, fills,
   spawn markers. Any pixel editor becomes the map editor.
5. Gray-shade fills separate tile shape from biome skin.
6. Pixel scenes for set pieces; noise generators for organic biomes.

## Sources

- [GDC: Exploring the Tech and Design of Noita (video)](https://www.youtube.com/watch?v=prXuyMCgbTc)
- [GDC Vault entry](https://www.gdcvault.com/play/1025695/Exploring-the-Tech-and-Design)
- [stb_herringbone_wang_tile.h (algorithm and template format)](https://github.com/nothings/stb/blob/master/stb_herringbone_wang_tile.h)
- [Noita Wiki: World generation](https://noita.wiki.gg/wiki/World_generation)
- [Noita Wiki: Biomes](https://noita.wiki.gg/wiki/Biomes)
- [Noita Wiki: Modding — Making a custom environment](https://noita.wiki.gg/wiki/Modding:_Making_a_custom_environment)
- [80.lv: Noita, a game based on falling sand simulation](https://80.lv/articles/noita-a-game-based-on-falling-sand-simulation)
