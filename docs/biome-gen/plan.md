# Plan: Biome Generation in Odin

Status: draft for adversarial review.

This plan follows the research in `noita-research.md`. It fits the
project rules: simplicity, ease of change, end-to-end performance,
testability, data-oriented fat structs, core/vendor libraries only.

## Goals

1. Generate an infinite 2D pixel world from a seed.
2. A small biome-map image controls the world layout.
3. Biomes generate from hand-painted herringbone wang tilesets.
4. Colors in tiles encode materials, biome fills, and spawn points.
5. Any chunk generates alone, in any order, deterministically.
6. Fast authoring loop: edit a PNG, see the result in seconds.

Non-goals for now: simulation, rendering the real game, entities.
Spawn points are recorded as data; nothing consumes them yet.

## Design decisions

### D1. World grid and chunks

- The world is an unbounded grid of **cells**. A cell holds a
  material ID.
- A **chunk** is 512x512 cells, like Noita. Chunk coordinates are
  `[2]i32`. Cell type is `u16` (room for >256 materials; 512 KiB
  per chunk; revisit if memory hurts).
- One biome-map pixel maps to exactly one chunk. This keeps the
  mapping trivial: `biome(chunk) = biome_map[chunk.x, chunk.y]`
  (with offset and out-of-bounds defaults).

```odin
Chunk :: struct {
    cells:  [CHUNK_SIZE * CHUNK_SIZE]Material_ID, // u16
    spawns: [dynamic]Spawn_Point,                 // filled by gen
}
Spawn_Point :: struct { pos: [2]i32, kind: Spawn_Kind }
```

### D2. Biome map and biome table

- `data/biome_map.png`, loaded with `core:image/png`. Each pixel
  color keys into the biome table. Above the map: sky biome. Below
  and beside: deep-rock biome (configurable defaults).
- `data/biomes.txt` uses the same `[Name] key = value` format as
  `materials.txt`, parsed the same way. Fields:

```
[Coalmine]
color     = FFD57917          # key in biome_map.png
generator = wang              # wang | noise | uniform
tileset   = data/tiles/coalmine.png
fill_0    = Rock              # gray shade 0 -> material
fill_1    = Dirt
fill_2    = Air
```

### D3. Herringbone wang tiles, stb-compatible template

- We implement the herringbone scheme in Odin, in the game package
  (~400 lines expected). We read the **stb template PNG layout**,
  including its metadata row. Reason: the format is proven, and
  existing stb tools can make templates while our own tool matures.
- Corner-constraint mode first (Noita-style variety, and the stb
  author recommends it); edge mode later only if needed.
- Default short side n = 128: horizontal tiles 256x128, vertical
  128x256. A 512x512 chunk covers a few dozen herringbone cells.
  n is per-tileset data read from the template header, not a
  constant in code.

### D4. Determinism without neighbor chunks (the key trick)

stb generates a whole map at once: it assigns random constraint
colors over the plane, then picks tiles that match. We split that
differently:

- **Constraint colors come from a hash, not from a PRNG stream.**
  The color at each herringbone lattice slot is
  `hash(world_seed, slot_pos) % num_colors`.
- Tile choice inside a chunk uses `hash(world_seed, chunk_pos)` to
  seed a local PRNG.

Two adjacent chunks compute the same colors on their shared border,
because the hash depends only on absolute slot position. So chunks
generate independently, in any order, with no seams — something even
Noita's sequential approach cannot claim cleanly.

Requirement this creates: the tileset must supply at least one tile
for **every** constraint-color combination. The loader validates
this and reports missing combinations. A fully painted stb template
satisfies it by construction.

Herringbone cells cross chunk borders. Rule: the chunk that contains
the tile's top-left corner is not special — **every chunk renders
the sub-rectangle of any tile that overlaps it.** Tile identity is a
pure function of (seed, lattice cell), so both chunks pick the same
tile and each blits its own part.

### D5. Paint semantics (Noita's, simplified)

Priority order per pixel of a tile:

1. Alpha 0 -> Air.
2. Exact match with a **spawn marker color** (`data/spawns.txt`,
   color -> Spawn_Kind) -> record spawn, place biome fill material.
3. Gray shades `FF101010, FF202020, ... FF808080` -> biome fill
   slots 0..7 from `biomes.txt`.
4. Exact match with a material `color` from `materials.txt` ->
   that material.
5. Anything else -> loader error with pixel position. No silent
   guesses; bad paint fails fast at load, not at play.

The tile loader compiles each tile PNG once into a
`[]Tile_Cell {material_or_fill_slot, spawn_kind}` so chunk
generation is a table copy, not per-pixel color matching.

### D6. Procedural generator

`generator = noise` biomes skip tiles: simplex fBm from
`core:math/noise`, threshold for cave vs solid, second channel for
ore veins. Parameters (frequency, octaves, threshold, materials)
live in `biomes.txt`. Same determinism rule: noise input is
absolute world position; seed offsets the noise domain.

`generator = uniform` fills one material (sky, deep rock). This is
also the phase-1 walking skeleton.

### D7. Map editor: preview tool first, not a paint program

Painting pixels is a solved problem (Aseprite, GIMP, anything).
Noita shipped without a custom editor. The real gap is **feedback**:
seeing how painted tiles stitch. So:

- `tools/tilegen`: writes an empty stb-compatible template PNG with
  guide lines and a palette strip of all material colors + gray
  fills + spawn markers, each labeled. Artists pick colors from the
  strip; exact-match semantics stay safe.
- `tools/biomeview`: opens a `vendor:raylib` window, generates a
  region from the real pipeline, draws it (each material's `color`).
  Watches the tileset/biomes/materials files and **regenerates on
  save**. Overlays on toggle: herringbone grid, constraint colors,
  chunk borders, spawn markers. Click a pixel -> material name.
  Reseed key. This closes the edit loop: paint in Aseprite, save,
  see the stitched biome instantly.
- An in-tool pixel brush is a later nice-to-have, only if the
  external-editor loop feels slow in practice.

Both tools are thin shells over the game package's own loader and
generator, so the tools test the real code path.

### D8. Testing

- Unit: biome/spawn table parsing; template metadata parse; tile
  slicing (counts, sizes); paint-semantics mapping incl. error
  cases; template coverage validation.
- **Determinism**: same seed -> byte-identical chunk. Different
  chunk generation order -> byte-identical world.
- **Seam test**: generate chunks A and B independently; assert the
  shared border came from the same tiles (this is the D4 guarantee,
  tested end to end).
- Golden test: fixed seed + committed mini tileset -> hash of the
  output region. Catches accidental behavior change; regenerate the
  hash deliberately when behavior should change.

All tests run with `odin test src` like the material tests.

## Phases

Each phase ends green-tested and demo-able via `biomeview`.

- **P0 — Toolchain spike (half a day).** Verify `core:image/png`
  loads an RGBA PNG, `core:math/noise` works, `vendor:raylib`
  opens a window and blits a texture. This container has no Odin;
  nothing below starts until P0 passes on a dev machine.
- **P1 — World skeleton.** Chunk struct, chunk store (map from
  coords), biome table, biome map loading, `uniform` generator.
  Demo: biomeview shows colored regions matching biome_map.png.
- **P2 — Herringbone core.** Template loader (stb layout), tile
  slicing, hash-lattice constraint colors, per-chunk generation
  with cross-border tile rendering. Seam + determinism tests.
  Demo: a hand-made 2-color test tileset stitches seamlessly.
- **P3 — Paint semantics.** Gray fills, direct materials, spawn
  markers, `spawns.txt`, loader errors. Golden test. Demo: one real
  authored biome (a coalmine-alike) with visible spawn overlays.
- **P4 — Tools polish.** tilegen guides + palette strip; biomeview
  hot reload, overlays, pixel inspector.
- **P5 — Noise biomes.** fBm caves + ore veins; a sky and a deep
  biome. Demo: biome map mixing wang and noise biomes.
- **P6 — Pixel scenes.** PNG stamps with the same paint semantics;
  random anchors from tiles + a global fixed-position list.

## Open questions (for the adversarial round)

1. `u16` vs `u8` cell type — 512 KiB vs 256 KiB per chunk.
2. Corner vs edge constraint mode as the first implementation.
3. n = 128 default: right tile size for authoring effort vs variety?
4. Should `Chunk.spawns` live in the chunk or in a separate table?
5. raylib for tools: acceptable vendor dependency, or SDL?
