# Plan: Biome Generation

This plan follows the research in `noita-research.md`.

The work is ordered as a series of end-to-end experiences. Each
slice delivers a complete, runnable loop that you can see and test.
Later slices deepen the same path. Nothing is built in isolation.

Priorities: simplicity, ease of change, end-to-end performance,
testability. Use the ponytail complexity ladder. Write prose in
Simplified Technical English.

## Goals

1. Generate an unbounded 2D pixel world from a seed.
2. A small biome-map image controls the world layout.
3. Biomes generate from authored herringbone wang tilesets.
4. Colors in tiles encode materials and biome fills.
5. Any region generates alone, in any order, deterministically.
6. Authoring is fast, and mistakes are reported at load.

Non-goals: background wall layer; spawn points and entities until
needed; biome blending (borders are hard cuts); chunk persistence
and streaming; depth-based variation; world edges; parallel worlds.

## Terms

- **Template slot**: one painted tile image in the template PNG.
- **Edge kind**: one of the 6 lattice edge kinds.
- **Fill slot**: one of the 8 gray shades that a biome maps to a
  material.
- **Paint class**: what one template pixel compiles to. It is Air,
  a fill slot 0..7, or a material ID. It is biome independent.

## Shared foundation (done once, used by every slice)

- One shared config tokenizer for `materials.txt`, `biomes.txt`, and
  tileset sidecars. A parse failure or unknown name is an error that
  names the file, line, and text. Color literals use explicit `0x`
  prefix handling.
- `Material_ID :: distinct u16`.
- Generation writes into a caller-owned `[]Material_ID` with width,
  height, and world origin. Signature intent:

  `generate(world: ^World, dest: []Material_ID, w, h: int,
  world_origin: [2]i32, seed: u64)`

- All world-to-region and world-to-lattice conversion uses floored
  division.
- `tools/forge` is one raylib binary. Modes are added when a slice
  needs them. Hot-reload by file modification time. Load errors are
  drawn in the window.

## Slice 1 — World editor with solid biomes

**Experience:** Open forge. See a solid square of one biome’s fill
material. Change the fill in a text file, hot-reload, and watch the
square change color. Click a pixel to read the material name.
Reseed and change the viewed region size.

What is built:

- Minimal `biomes.txt` with `[Map]` and one biome that uses
  `generator = uniform` and a single fill material.
- Tiny `biome_map.png` (even 1×1 is enough).
- Biome table and map loading with hard errors for unmatched map
  colors, missing required keys, duplicate names or key colors, and
  unresolved name references.
- Uniform generator that fills the requested rectangle with the
  biome’s material.
- Forge Preview mode: render the generated region with material
  display colors, chunk-size stepper, reseed, pixel inspect, hot
  reload.

Tests: determinism, off-map and above-map rules, validation errors.

This is the first complete vertical path: data → load → generate →
render → interact.

## Slice 2 — Biome tile editor (basic)

**Experience:** Switch to a simple tile editor. Paint a solid or
simple patterned rectangle for the biome. Save. Return to Preview
and see that pattern fill the biome region instead of the solid
color.

What is built:

- Minimal tileset sidecar and PNG.
- Basic Tileset mode in forge: load the image, constrained palette
  from materials and the eight gray fills, paint pixels, save.
- Preview uses the tile when present; otherwise falls back to the
  solid fill from Slice 1.

No herringbone lattice yet. The vertical path is now: paint a tile
→ it appears in the world editor.

## Slice 3 — Herringbone tiles on the same path

**Experience:** The same world editor now shows seamless herringbone
terrain for the biome. Change the seed and the arrangement changes,
still seamless. Toggle lattice overlays. Click a pixel and see the
tile and source template slot that produced it.

What is built:

- Tileset sidecar parsing with dimension validation and range
  checks.
- Lattice geometry: `class`, corner class tables per orientation,
  edge kinds, `slot_rect`, image layout formula.
- Position-hash determinism (`mix` from splitmix64 finalizer with
  pinned constants). Corner colors and tile choice from seed +
  biome key color (as `biome_salt`) + position.
- `tiles_overlapping` iterator (no allocation).
- Template slicing, cross-border blit, slot coverage check, seam
  lint over paint classes.
- Provisional paint mapping: alpha 0 → Air, any other pixel → one
  test material.

Start art at `colors = 1 1 1 1`, `vary = 1` (two slots). Raise counts
only after the pipeline is proven.

Tests: determinism, seams (including across world origin and biome
borders), dimension mismatch, all-alpha-0 slots, seam-lint negative
fixture.

## Slice 4 — Full paint semantics and multi-fill

**Experience:** One tileset is re-skinned by two biomes with
different fill mappings. The same shapes appear with different
materials. Invalid colors report the exact pixel. A golden test
locks the output of a fixed seed.

What is built:

- `wang_color` in the cold material table (separate from display
  color).
- Gray fill shades 0..7 resolve through the biome’s fill table at
  blit time (reserved IDs `0xFFF8..0xFFFF`).
- Color disjointness, fill coverage, load errors with positions.
- Golden test pinned to seed, region size, and biome key colors.
- Blit benchmark (target ~1 ms for 512×512 at n=64). Measure before
  any extra compilation cache.

## Slice 5 — Advanced tileset authoring tools

**Experience:** Open the tileset editor and paint a proper boundary
vocabulary (edge strips and corner hubs). Compose a full template
from those parts. Seam lint and dead-end warnings mark problems in
place. You can still hand-edit any slot afterward. Composition does
not overwrite newer hand work unless forced.

What is built:

- Full Tileset mode: constrained palette, info panel (slot index,
  corners, classes, memory cost), edge strips keyed on lattice edge
  kind + endpoint colors, corner hubs, join rule, composition
  scaffold with timestamp check and `--force`.
- Dead-end warning (forge only) that resolves fills through the
  selected biome.
- Optional: World Map mode (palette of biomes, large squares per
  region) once more than one biome exists. Until then export a
  `.gpl` palette for external editors.

Composition writes a normal template PNG. The engine format does
not change. This slice is pure tooling; no finished biome is
required yet.

## Slice 6 — First real biome and noise biomes

**Experience:** Author a coherent Coalmine using the tools from
Slice 5. Add Sky and Deep_Rock (uniform or noise). The world map
now has multiple biomes. The same Preview and generation path still
work. Raise color counts only as far as the art budget allows.

What is built:

- First real Coalmine-like biome.
- Noise generator (OpenSimplex2 + short fBm, or integer value-noise
  built on `mix` if cross-platform float determinism is required).
  Decide the float question before this slice ships.
- Uniform and noise biomes on the existing map.
- Pixel scenes and spawn markers only when the entity system needs
  them.

## Design rules that every slice obeys

### World grid and regions

- A cell holds a `Material_ID`.
- One biome-map pixel is one region (default 512 cells;
  `cells_per_pixel` overrides).
- A chunk is only a cut: how much the caller asks for. There is no
  chunk store until streaming exists.
- Chunk size changes only the cut, never the terrain.

### Biome map and table

```
[Map]
image         = data/biome_map.png
origin_pixel  = 35 12
biome_off_map = Deep_Rock
biome_above   = Sky          # optional

[Coalmine]
color     = 0xFFD57917
generator = wang             # wang | noise | uniform
tileset   = data/tiles/coalmine.png
fill_0    = Rock
fill_1    = Dirt
fill_2    = Air
```

Hard load errors for: unmatched map pixel colors, missing required
keys, unresolved names, duplicate names or key colors. The biome
key color is also `biome_salt` (terrain input). Do not change it
after art ships.

### Herringbone lattice (Slice 3+)

- Horizontal tiles 2n×n, vertical tiles n×2n.
- Six corner points and six boundary segments per tile.
- Only six edge kinds are boundaries.
- Corner class tables (horizontal origin class 1, vertical origin
  class 0) set the radices for slot indexing.
- Edges belong to the lattice, not to a tile orientation.
- Slot counts and image size formula are derived and checked.
- Our own block layout (no stb compatibility required).

Tileset sidecar:

```
[Tileset]
n      = 64
colors = 2 2 1 1
vary   = 2
```

### Determinism

- Every random-looking decision is a position hash with its own
  salt. No PRNG streams.
- `biome_salt` = biome key color.
- Neighbors agree by construction; generation never reads a
  neighbor region.

### Paint semantics (Slice 4+)

1. Alpha 0 → Air.
2. Exact gray fill shades → fill slot 0..7.
3. Material `wang_color` → that material.
4. Anything else → load error with pixel position.

### What is cut until needed

- Spawn tables and entity markers.
- Chunk pool / store.
- Per-(biome, tileset) resolved tile copies (measure first).
- Procedural interior carver.
- Avalanche test for `mix`.

## Authoring workflow (once Slice 5 exists)

1. Write a `[Tileset]` sidecar. Start at `colors = 1 1 1 1`,
   `vary = 1`.
2. Paint the boundary vocabulary. Compose every template slot.
3. Open Preview. The stitched world appears.
4. Paint detail into weak slots. Seam lint and dead-end warnings
   mark problems on reload.
5. Raise `colors` one class at a time only as far as the art budget
   allows.

## Testing (accumulated across slices)

- Unit tests for tokenizer, geometry tables, `slot_rect`, paint
  rules, validation cases.
- Determinism and seam tests (including origin and biome borders).
- Seam-lint negative fixture.
- Golden test for world regeneration safety.
- Performance print (not assert) for generation time.

All tests run with `odin test src` from the repository root.

## Later

World Map mode refinement, background layer, streaming, chunk
store, and pool when the game needs them.
