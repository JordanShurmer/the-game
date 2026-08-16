# Plan: Biome Generation in Odin

Status: revision 3. Audited against the ponytail complexity ladder
and the README principles. See "Revision notes" at the end.

This plan follows the research in `noita-research.md`.

## The ladder audit

The project rule is the ponytail complexity ladder. Every component
below must answer these questions in order:

1. Does this need to exist? If no, skip it.
2. Does the standard library do it? Use it.
3. Is there a native platform feature? Use it.
4. Is there an installed dependency? Use it.
5. Can it be one line? Make it one line.
6. Only then write the minimum that works.

Correctness and data loss are outside the "skip it" calculus. The
determinism rules in D4 are correctness, not gold plating.

Revision 3 cut these on rung 1:

| Cut | Why | When it returns |
| --- | --- | --- |
| Spawn table, `Spawn_Point`, spawn store, spawn overlay | Nothing consumes spawns. No entity system exists. | With the entity system. Markers are sparse pixels, so tiles need only a touch-up, not a repaint. |
| Chunk pool and free list | Only a viewer allocates chunks. `new` is one line and correct. | With chunk streaming. |
| Border-strip continuity warning | D7 composition makes edge continuity structural. A warning about an impossible state is dead code. | Never, if composition holds. |
| Template coverage validation | Composition writes every slot. Coverage cannot fail. | Only if hand-authored templates bypass the tool. Keep a cheap assert. |
| `vary_x` / `vary_y` beyond 1 | Variety is not yet a measured problem. | When repetition is visible in the preview. The generator already divides by `len(candidates)`, so this is a data change only. |

Revision 3 kept these, with the rung that justifies them:

- `core:image/png` decode (rung 2), `vendor:stb/image` encode
  (rung 4), `vendor:raylib` window (rung 4), `core:math/noise`
  (rung 2), raygui widgets if bundled (rung 4, verify in P0).
- Our own `mix` hash (rung 6). `core:math/rand` cannot be used:
  its algorithm may change between compiler releases, which would
  silently regenerate every world. This is a correctness boundary.
- One tool binary, not four (rung 5 in spirit): `tools/forge`
  shares one window, one palette renderer, one file loader, and
  one generator across all modes.

## Goals

1. Generate an unbounded 2D pixel world from a seed.
2. A small biome-map image controls the world layout.
3. Biomes generate from authored herringbone wang tilesets.
4. Colors in tiles encode materials and biome fills.
5. Any chunk generates alone, in any order, deterministically.
6. Authoring is fast and cannot produce an invalid tileset.

Non-goals for now, recorded so we do not drift into them:

- **Background wall layer.** Deferred by decision. Migration path:
  add a parallel `background` array to the chunk, and give each
  tileset a companion `<name>_bg.png` with the same slot layout.
  Cost: tiles painted before then have no background data.
- **Spawn points and entities.** See the ladder audit. When they
  arrive, pick marker colors then. The disjointness check (D5)
  makes any collision with existing art a loud load error.
- **Biome blending.** Biome borders are hard cuts (D4). Noita does
  the same and hides borders with map authoring and set pieces.
- **Chunk persistence and streaming.** Generation is pure, so
  chunks regenerate. Persistence is a simulation-phase decision.
- **Depth-based variation, world edges, parallel worlds.** Later.

## Design decisions

### D1. World grid and chunks

- The world is an unbounded grid of cells. A cell holds a material
  ID (`u16`). 256 materials fit in `u8`, but the saved 256 KiB per
  chunk buys nothing we need.
- A chunk is `chunk_size` x `chunk_size` cells. Chunk coordinates
  are `[2]i32`. Generation takes the size as a parameter and writes
  into a `[]Material_ID` slice with explicit dimensions. The game
  binds the default, 512, in one place. forge overrides it from a
  UI control (D7).
- Chunks are plain data: one array, no dynamic fields, no pointers.
  Determinism tests then compare chunks with `mem.compare`.
- The chunk store is `map[[2]i32]^Chunk`, allocated with `new`.
  Pointers, not values: a map rehash would move every chunk and
  dangle every pointer into it. A 512 KiB chunk also never goes on
  the stack, because some platforms give worker threads 1 MiB.
- Future simulation needs per-cell flags, shade, and sparse
  velocity. Those become parallel arrays inside the chunk, not a
  fat per-cell struct. Most cells are static, so a fat cell would
  drag dead bytes through cache. Heap chunks make this additive.

```odin
CHUNK_SIZE :: 512 // the game's binding of the size parameter

Chunk :: struct {
    cells: [CHUNK_SIZE * CHUNK_SIZE]Material_ID, // u16
}
```

### D2. Biome map and biome table

- `data/biome_map.png`, decoded with `core:image/png`. One map
  pixel is one chunk.
- `data/biomes.txt` uses the `[Name] key = value` format and the
  parser style of `materials.txt`. A `[Map]` section pins the
  coordinate convention, so nothing is implicit:

```
[Map]
image        = data/biome_map.png
origin_pixel = 35 12        # this pixel is chunk (0, 0)
biome_above  = Sky          # off-map defaults
biome_below  = Deep_Rock
biome_beside = Deep_Rock

[Coalmine]
color     = 0xFFD57917      # key color in biome_map.png
generator = wang            # wang | noise | uniform
tileset   = data/tiles/coalmine.png
fill_0    = Rock            # gray shade 0 -> material
fill_1    = Dirt
fill_2    = Air
```

- All data files use one color convention: `0xAARRGGBB`, as in
  `materials.txt`. The PNG decoder gives RGBA bytes. One tested
  procedure converts them to `u32` ARGB.
- Finer biome shapes later need only a `cells_per_pixel` key. The
  code reads the mapping from data now, so that change stays local.

### D3. Herringbone wang tileset format

- We implement the herringbone scheme in Odin, in the game package.
  Corner-constraint mode. Corner mode pre-assigns a color per
  lattice point, which is exactly what our hash replaces (D4).
- Tiles are 2:1 rectangles: horizontal 2n x n, vertical n x 2n.
  Default n = 64. The loader requires `chunk_size % n == 0` and
  `n <= chunk_size / 2`. Chunk borders then stay on the tile grid,
  so a tile meets at most 2 chunks and never a chunk corner.
- The template PNG keeps the stb slot layout, because that geometry
  is proven and documented. We do not read stb's pixel-encoded
  metadata row. A sidecar file carries the config:

```
# data/tiles/coalmine.txt
[Tileset]
n      = 64
colors = 2 2 2 2   # corner classes c0..c3
vary   = 1         # alternatives per combination
```

- Combinatorics set the color budget. A corner-mode template holds
  `c^6` tiles per orientation at uniform color count c: c=1 gives 2
  tiles total, c=2 gives 128, c=3 gives 1458. Hand painting stops
  being possible above c=2. D7 composition removes that ceiling as
  a manual cost, because the tool writes the slots.

### D4. Determinism without neighbor chunks (the core mechanism)

stb generates a whole map at once. It pre-assigns random corner
colors over a grid, then picks a matching tile per herringbone
cell. We keep that structure and replace both random streams with
position hashes. Any chunk then computes any lattice value locally,
and adjacent chunks agree by construction.

- **The lattice.** Corner points sit on the n-grid, anchored at
  world cell (0, 0). Each point has a class 0..3, set by its
  position within the herringbone period. All lattice math uses
  floored division and floored modulo (Odin `%%`). Truncating `%`
  would break chunks left of or above the origin.
- **Corner colors.** `color(p) = mix(seed, p.x, p.y, SALT_CORNER)
  %% num_colors[class(p)]`. Per-class moduli, not one global count.
- **Tile choice.** The six corner colors of a herringbone cell
  select the template slot. Then
  `tile = mix(seed, c.x, c.y, SALT_TILE) %% len(candidates)`.
  The cell ID `(c.x, c.y)` is the tile's origin corner in n-grid
  units. Orientation is a pure function of position, so it is not
  a hash input. All lattice coordinates are in n-units.
- **One enumeration procedure.** `tiles_overlapping(rect, n)`
  returns every tile that touches a rectangle: origin, orientation,
  and the overlap sub-rectangle. Chunk generation and the preview
  both call it, so there is one definition of the lattice and one
  place to test it. At n=64 and chunk 512 it returns 36 tiles: 28
  whole and 8 split at a border.
- **No PRNG streams in worldgen.** A seeded stream makes results
  depend on draw order, and draw order differs per chunk. Every
  random-looking decision is a position hash with its own salt.
  `mix` is our own splitmix64-style mixer with a documented input
  encoding.
- **Chunk rendering.** For each overlapping tile, compute its
  identity from the hashes, then blit the overlap sub-rectangle. A
  tile that crosses a chunk border is computed identically by both
  chunks, and each blits its own part.
- **Dropped: stb's repetition-reduction pass.** stb mutates the
  corner-color grid in sequence to break up repeats. A sequential
  global pass cannot run per chunk. If repetition looks bad in the
  preview, the recorded upgrade is a hash-local variant: flip a
  corner when its fixed-size neighborhood of base hash colors
  matches a repeat pattern. That stays deterministic and order
  free.
- **Biome borders.** The lattice, tileset, and hashes are scoped
  per biome. A chunk generates from its own biome only. A chunk
  never inspects a neighbor biome, because it only writes cells
  inside its own rectangle. Clipping at a biome border is therefore
  the same code path as clipping at the chunk rectangle, and no
  cell is left undefined. Two biomes with different n never
  interact.

### D5. Paint semantics

Each material gets a `wang_color`: the color that represents it in
authored PNGs. It defaults to the display `color`, but it is a
separate value in the cold parallel table. `Material_Table` gains a
`wang_colors: []u32` slice. The hot 32-byte `Material` struct does
not change. Reason: display colors must stay tunable without
repainting art, and two materials may share a display color but
never a paint key.

Priority order per template pixel:

1. Alpha 0 gives Air.
2. A gray fill shade gives a biome fill slot 0..7. These are
   exactly the 8 values `0xFF101010, 0xFF202020, ... 0xFF808080`,
   step `0x10` per channel. Other grays stay available as wang
   colors.
3. A material `wang_color` gives that material.
4. Anything else is a load error that reports the pixel position.

Color keys must have alpha `0xFF`. Air is the exception: its
display color is `0x00000000`, so rule 1 covers it.

The loader validates the tables against each other. Gray fill
shades and material wang colors must be disjoint. A collision is a
load error that names both owners. Without this check, the priority
order would silently shadow a material. `Smoke (0xFF555555)` and
`Rock (0xFF6B6B6B)` are already gray; the exact-8-values rule keeps
their default wang colors legal.

The loader also checks fill coverage. Every biome must define every
fill slot that its tileset uses. An undefined slot is a load error,
not a silent default.

**Tile compilation and the blit.** Each template slot compiles once
into a flat `[]u16`. Fill slots could compile to reserved IDs and
resolve during the blit, but that puts a branch on every cell, and
fills are the majority of cells. Instead the compile step is
**per (biome, tileset) pair**: fill slots resolve to concrete
material IDs at bind time, so the blit is a plain per-row memcpy.
Cost is about 2 MiB per pair at n=64 and c=2, which is trivial.
Target: a chunk generates in under 1 ms. Measure in P2.

### D6. Noise and uniform generators

- `generator = uniform` fills one material. Sky and deep rock use
  it, and it is the P1 walking skeleton.
- `generator = noise` uses OpenSimplex2 from `core:math/noise`
  with our own short fBm octave loop, because core has no fBm. A
  threshold picks cave or solid. A second channel places ore veins.
  Parameters live in `biomes.txt`:

```
[Fungal_Depths]
color       = 0xFF8040C0
generator   = noise
frequency   = 0.008
octaves     = 4
threshold   = 0.1
solid       = Rock
open        = Air
vein        = Gold
vein_freq   = 0.02
vein_cut    = 0.75
```

- Noise input is absolute world position. The seed offsets the
  noise domain. Same determinism rule as D4.
- Determinism scope: the game ships one artifact per platform, with
  platform differences handled by compile-time checks
  (`when ODIN_OS == ...`). "Deterministic" means same seed and same
  build give the same world. Cross-platform bit-identity is not a
  requirement, so float noise is fine. Wang biomes are integer math
  and portable anyway.

### D7. forge: one tool, three modes

`tools/forge` is a single `vendor:raylib` binary. It shares one
window, one palette renderer, one file loader, and one generator
across three modes. It is a thin shell over the game package, so it
exercises the real code path. Widgets come from raygui if the Odin
distribution bundles it (rung 4, verify in P0). If not, a stepper
and a button are a few lines each.

**Common to all modes:** hot reload by polling file modification
times each frame, because raylib has no file watcher. Load errors
draw in the window at the offending pixels, not only in the
console.

#### Mode 1: World Map

The biome map is tiny: one pixel per chunk, about 70 pixels wide
for a Noita-sized world. Editing that in Aseprite means zooming to
3200% and painting single pixels whose colors carry no visible
meaning. This mode replaces that.

- Draws the map as a grid of large squares, one square per chunk.
- The palette lists biomes **by name**, read from `biomes.txt`.
- Paint, fill, and pick with the mouse. Each square writes one
  pixel.
- Info panel: hovered chunk coordinate, biome name, generator kind,
  and the world cell rectangle that chunk covers.
- Saves the PNG through `vendor:stb/image`. Only the biome colors
  in `biomes.txt` can ever be written, so an unmatched color is
  impossible.

#### Mode 2: Tileset

This is the mode that removes the plan's biggest risk. Painting 128
slots by hand and keeping their edges continuous is the part that
Aseprite cannot help with, because Aseprite does not know the
constraint rules.

**Composition is the core idea.** In corner mode, the pixels along
a tile edge must depend only on the two corner colors at that
edge's endpoints. So the artist does not paint tiles. The artist
paints a small set of parts, and forge composes every slot:

- **Edge profiles.** One strip per (orientation, endpoint color
  pair). Every lattice edge is n long, because the long side of a
  tile is split by its middle corner point. At c=2 that is 2
  orientations x 2 x 2 color pairs = 8 strips.
- **Corner hubs.** A small patch around each lattice point, one per
  corner class and color.
- **Interiors.** One or more fills per enclosed region type.

forge composites these into all `c^6` slots and writes a normal
template PNG. Two consequences follow, and both are large:

1. **Edge continuity is structural.** Two tiles that meet always
   share the same edge profile, so a seam cannot mismatch. This
   removes a whole class of bugs, and it removes the need for a
   border-strip warning.
2. **Coverage is structural.** Every combination gets written, so
   the coverage check cannot fail. Art cost stops growing with
   `c^6` and grows with the number of parts instead.

The output is an ordinary template PNG. The engine format does not
change, and a composed template can still be hand-edited afterward
for special slots. Composition is a tool feature, not a runtime
feature, so it adds no new failure mode to generation.

Other mode features:

- Paint with squares that map to single pixels, like Mode 1, at a
  zoom the artist controls.
- The palette is constrained by construction: material wang colors
  by name, the 8 gray fills labeled with the biome material each
  currently resolves to, and nothing else. Off-palette colors and
  anti-aliasing are impossible, which kills the two classic
  footguns without relying on editor settings.
- Info panel: slot index, its six corner colors, tile counts, and
  memory cost of the current `n` and `colors`.
- Round-trip: the template PNG stays a normal PNG, so Aseprite can
  still edit it for detail work.

#### Mode 3: Preview

- Generates a region through the real pipeline and draws it with
  material display colors.
- Overlays on toggle: chunk borders, the herringbone lattice with
  corner colors, and biome map regions.
- Click a pixel to see the material name, tile ID, and the tile's
  source rectangle in the template. A bad seam then points back to
  the slot that made it.
- Steppers for `n` and `chunk_size`, snapping to
  `chunk_size %% n == 0`, so we can feel how the sizes affect
  structure and repetition before the game pins its defaults. A
  painted template matches only its own n, so an override switches
  to generated debug tiles, and size experiments need no repainted
  art.
- Reseed key.

### D8. Testing

All tests run with `odin test src`, like the material tests.

- Unit: biome and sidecar parsing; RGBA to ARGB conversion; the
  lattice class function, including negative coordinates;
  `tiles_overlapping` counts, orientations, and sub-rectangles;
  paint-semantics mapping and every error case; color disjointness;
  fill coverage.
- Determinism: one seed gives `mem.compare`-identical chunk cells.
  A different chunk generation order gives an identical world.
- Seam tests: two adjacent chunks generated independently share
  identical border cells. A biome-border case checks that clipping
  is stable and both sides are deterministic.
- Composition test: for a composed tileset, every pair of slots
  that share an edge signature has identical edge pixels. This
  tests the D7 guarantee directly, in the engine, without the tool.
- Hash quality: a unit test asserts `mix` passes an avalanche
  sanity check, so lattice sampling shows no obvious period.
- Golden test: a fixed seed and a small committed tileset give a
  known hash of the output region. Regenerate that hash only on
  purpose. Goldens hold per platform build (D6).
- Performance: a benchmark asserts chunk generation stays under
  1 ms at n=64 and chunk 512.

## The authoring workflow, end to end

1. Open forge, World Map mode. Paint biome regions by name. Save.
2. Switch to Tileset mode. Paint the edge profiles, corner hubs,
   and interiors for the biome. forge composes all slots.
3. Switch to Preview mode. The stitched world appears immediately.
4. Fix any slot that looks wrong by clicking it in Preview, which
   names the slot, then editing that part in Tileset mode.
5. Ramp: start at `colors = 1 1 1 1`, which is 2 slots and proves
   the pipeline. Then `2 2 2 2`, which is 128 slots composed from
   about 8 edge strips, a few hubs, and a few interiors.

## Phases

Each phase ends green-tested and demo-able in forge.

- **P0 — Toolchain spike, half a day.** On a dev machine, because
  this planning container has no Odin. Verify: `core:image/png`
  decodes RGBA and indexed PNGs; `vendor:stb/image` writes PNGs;
  `core:math/noise` runs; `vendor:raylib` opens a window, blits a
  texture, and reads file modification times; whether raygui ships
  with the distribution. Any failure changes D7 before code exists.
- **P1 — World skeleton and forge Preview + World Map.** Chunk
  store, biome table with `[Map]`, biome map loading, `uniform`
  generator. Demo: paint biome regions by name in World Map mode,
  and see them in Preview with hot reload.
- **P2 — Herringbone core.** Sidecar parsing, template slicing,
  the lattice, `mix`, `tiles_overlapping`, per-chunk generation
  with cross-border blitting. P2 uses a provisional paint mapping:
  alpha 0 gives Air, and any other pixel gives one test material.
  D5 replaces that in P3. Determinism, seam, and performance tests.
  Demo: a `1 1 1 1` and then a `2 2 2 2` debug tileset stitching
  seamlessly across chunk borders.
- **P3 — Paint semantics.** `wang_color` in the cold table, gray
  fills, disjointness, fill coverage, per-pair compilation, load
  errors with positions, golden test. Demo: one tileset re-skinned
  two ways by two biomes.
- **P4 — forge Tileset mode and the first real biome.** Edge
  profiles, corner hubs, interiors, composition, the constrained
  palette, the info panel, and the composition test. Then author a
  coalmine-alike at `2 2 2 2`. Authoring is the riskiest
  unvalidated step, so it gets its own phase and drives the tool.
- **P5 — Noise biomes.** The fBm wrapper and its tests, ore veins,
  and sky and deep-rock biomes in the map. Demo: a biome map that
  mixes wang, noise, and uniform biomes.
- **P6 — Pixel scenes.** PNG stamps with D5 semantics, placed from
  anchor markers plus a global fixed-position list. Demo: a set
  piece that stays intact across a chunk border.

## Revision notes

Revision 3 (ladder audit and tooling):

- Verified the ponytail complexity ladder and audited every
  component against it. Added the audit table.
- Cut on rung 1: the spawn system, the chunk pool, the border-strip
  warning, coverage validation, and `vary` above 1.
- Added forge: one binary with World Map, Tileset, and Preview
  modes, replacing two planned binaries and their duplicated
  shells.
- Added edge-profile composition to Tileset mode. This makes edge
  continuity and slot coverage structural rather than checked, and
  it decouples art cost from `c^6`.
- Added `tiles_overlapping` as the single lattice definition.
- Changed tile compilation to per (biome, tileset) pair, so the
  blit is a memcpy instead of a branch on every cell.
- Added a 1 ms chunk generation budget and a benchmark for it.

Revision 2 (verification pass): provisional paint mapping for P2;
corrected the per-chunk tile count to 28 whole and 8 partial;
pinned the tile-choice hash input; made gray fills exactly 8
values; required alpha `0xFF` on color keys; added fill coverage
and the no-neighbor-lookup simplification.

Revision 1 (three adversarial reviews): fixed a self-contradiction
where tile choice used a chunk-seeded PRNG, which broke the seam
guarantee; added per-biome lattice scoping for biome borders;
specified the lattice, per-class moduli, floored modulo, and our
own mixer; ran the `c^6` combinatorics and capped colors at 2;
closed the PNG encode hole with `vendor:stb/image`; made chunks
pooled POD behind pointers; split `wang_color` from display
`color`; resequenced the tools; added the indexed palette and
other authoring defenses.
