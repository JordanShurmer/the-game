# Plan: Biome Generation in Odin

Status: revised after adversarial review round 1. See "Revision
notes" at the end.

This plan follows the research in `noita-research.md`. It fits the
project rules: simplicity, ease of change, end-to-end performance,
testability, data-oriented design, core/vendor libraries only.

## Goals

1. Generate an unbounded 2D pixel world from a seed.
2. A small biome-map image controls the world layout.
3. Biomes generate from hand-painted herringbone wang tilesets.
4. Colors in tiles encode materials, biome fills, and spawn points.
5. Any chunk generates alone, in any order, deterministically.
6. Fast authoring loop: edit a PNG, save, see the stitched result.

Non-goals for now, recorded so we do not drift into them:

- **Background wall layer.** Noita's look uses a second layer behind
  the terrain. We defer it. Migration path: pooled chunks (D1) let
  us add a parallel `background` array later, and each tileset can
  gain a companion `<name>_bg.png` with the same slot layout.
  Cost of deferral: tiles painted before then have no background
  data. We accept this for the first tilesets.
- **Biome blending.** Biome borders are hard cuts (D4). Noita does
  the same and hides borders with map authoring and set pieces.
- **Depth-based spawn and ambience variation.** Later, in the biome
  table.
- **Chunk persistence.** Generation is pure, so chunks regenerate.
  How simulated changes persist is a simulation-phase decision.
- **World edge behavior and parallel worlds.** Later.

## Design decisions

### D1. World grid and chunks

- The world is an unbounded grid of cells. A cell holds a material
  ID (`u16`). 256 materials would fit in `u8`, but the saved 256 KiB
  per chunk buys nothing we need.
- A chunk is 512x512 cells, like Noita. Chunk coordinates are
  `[2]i32`.
- Chunks are plain data: one fixed array, no dynamic fields, no
  pointers. Determinism tests can then compare chunks with
  `mem.compare`.
- The chunk store maps coordinates to **pointers**:
  `map[[2]i32]^Chunk`, with chunks from a pool (free list of
  uniform 512 KiB blocks). Never store `Chunk` by value in the map:
  a rehash would move and copy every live chunk and dangle every
  pointer into it. Never put a `Chunk` on the stack: 512 KiB
  overflows worker-thread stacks on some platforms.
- Spawn points live **outside** the chunk in their own store
  (for example `map[[2]i32][]Spawn_Point`), filled during
  generation. This keeps `Chunk` pure and gives the future entity
  system one place to read.
- Future simulation needs per-cell flags, shade, and sparse
  velocity. The plan for that is parallel arrays **inside the
  chunk** (`materials`, `flags`, `shade`), not a fat per-cell
  struct. Most cells are static; a fat cell drags dead bytes
  through cache. Pooled heap chunks make adding arrays additive.

```odin
CHUNK_SIZE :: 512

Chunk :: struct {
    cells: [CHUNK_SIZE * CHUNK_SIZE]Material_ID, // u16
}

Spawn_Point :: struct {
    pos:  [2]i32, // world cells
    kind: u16,    // index into the spawn table
}
```

### D2. Biome map and biome table

- `data/biome_map.png`, loaded with `core:image/png` (decode is
  core; encode is not — see D7). One map pixel is one chunk.
- `data/biomes.txt` uses the same `[Name] key = value` format and
  parser style as `materials.txt`. A `[Map]` section pins the
  mapping so no coordinate convention is implicit:

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

- All colors in all data files use one convention: `0xAARRGGBB`,
  the `materials.txt` style. The PNG loader gives RGBA bytes; the
  loader converts to `u32` ARGB once, in one tested procedure.
- If we later want biome shapes finer than one chunk, we add a
  `cells_per_pixel` key to `[Map]`. The code reads the mapping from
  data now, so that change stays local.

### D3. Herringbone wang tileset format

- We implement the herringbone scheme in Odin, in the game package.
  Corner-constraint mode. Reason: the per-position color
  pre-assignment in corner mode is exactly what our hash scheme
  replaces (D4), so the substitution is faithful to stb's own
  algorithm.
- Tiles are 2:1 rectangles: horizontal 2n x n, vertical n x 2n.
  Default **n = 64**. The loader requires `CHUNK_SIZE % n == 0` and
  `n <= 256`. This keeps chunk borders on the tile grid, so a tile
  crosses at most one chunk border (2 chunks, never 4).
- The template PNG keeps the **stb slot layout** (all tiles for all
  color combinations, in stb's order), so the geometry is proven
  and documented. We do **not** use stb's pixel-encoded metadata
  row. A sidecar file in our standard format carries the config:

```
# data/tiles/coalmine.txt
[Tileset]
n      = 64
colors = 2 2 2 2   # corner classes c0..c3, each 1 or 2 for now
vary_x = 1         # duplicate slots per combination = variety
vary_y = 1
```

- Combinatorics decide the color budget. A corner-mode template
  holds `c^6` tiles per orientation for uniform color count c:
  c=1 -> 2 tiles total, c=2 -> 128, c=3 -> 1458. **Color counts
  stay at 2 or lower until further notice.** More variety comes
  from `vary` (extra hand-painted alternatives per combination),
  which costs art linearly, not exponentially.
- The loader validates: template dimensions match the sidecar;
  every combination has at least one tile; it prints the tile
  budget (count and pixels) so art cost is visible up front.

### D4. Determinism without neighbor chunks (the core mechanism)

stb generates a whole map at once: it pre-assigns random corner
colors over a grid, then picks matching tiles per herringbone cell.
We keep that structure and replace both random streams with
position hashes. Then any chunk computes any lattice value locally,
and adjacent chunks agree by construction.

- **The lattice.** Corner points sit on the n-grid, anchored at
  world cell (0, 0). Each corner point has a class 0..3 assigned by
  position parity within the 4n herringbone period, exactly as stb
  assigns them. All lattice math uses floored division and floored
  modulo (Odin `%%`); truncating `%` breaks chunks left of or above
  the origin.
- **Corner colors.** `color(p) = mix(seed, p.x, p.y, SALT_CORNER)
  %% num_colors[class(p)]`. Per-class moduli, not one global count.
- **Tile choice.** For herringbone cell c, the six relevant corner
  colors select the candidate list (the template slot for that
  combination, `vary` tiles long, in template order). Then
  `tile = mix(seed, c.x, c.y, SALT_TILE) %% len(candidates)`.
- **No PRNG streams anywhere in worldgen.** A seeded stream makes
  results depend on draw order, and draw order differs per chunk.
  Every random-looking decision is a pure position hash with its
  own salt. `mix` is our own splitmix64-style mixer, about 20
  lines, with a documented input encoding. We do not use
  `core:math/rand` or core hash internals: their algorithms can
  change between compiler releases and would silently regenerate
  every world.
- **Chunk rendering.** A chunk intersects its rectangle with the
  lattice, enumerates every overlapping tile (about 8 whole tiles
  at n=64 chunk-interior, plus partials), computes each tile's
  identity from the hashes, and blits the overlapping
  sub-rectangle. A tile crossing a chunk border is computed
  identically by both chunks; each blits its own part.
- **Dropped: stb's repetition-reduction pass.** stb mutates the
  corner-color grid sequentially to break up repeats. A sequential
  global pass cannot run per-chunk. We accept more visible
  repetition and counter it with `vary` tiles. If repetition still
  hurts, the recorded upgrade is a hash-local variant: flip a
  corner if its fixed-size neighborhood of *base* hash colors
  matches a repeat pattern — deterministic, order-free, bounded
  window.
- **Biome borders.** The lattice, tileset, and hashes are scoped
  **per biome**. A chunk generates from its own biome only. A tile
  that would cross into a chunk of another biome is clipped at the
  border; the neighbor renders its own biome there. Borders are
  hard cuts by design (see non-goals). Two wang biomes with
  different `n` never interact, because neither renders into the
  other's chunks. The seam test suite (D8) includes a
  biome-border case.

Requirement created by pre-fixing all six constraints: the tileset
must cover **every** color combination (a fully painted template
does, by construction — that is why color counts stay small).
Under-painted templates fail at load with the missing combinations
listed.

### D5. Paint semantics

Each material gets a **`wang_color`**: the color that represents it
in authored PNGs. It defaults to the display `color` but is a
separate value in the cold parallel table (`Material_Table` gains a
`wang_colors: []u32` slice; the hot 32-byte `Material` struct does
not change). Reason: display colors must stay tunable without
repainting every authored tile, and two materials may share a
display color but never a paint key.

Priority order per template pixel:

1. Alpha 0 -> Air.
2. Spawn marker color (`data/spawns.txt`: color -> spawn name) ->
   record a spawn point, place the biome's fill_0 material.
3. Gray shades `0xFF101010 ... 0xFF808080` -> biome fill slots 0..7.
4. Material `wang_color` -> that material.
5. Anything else -> load error with template pixel position.

The loader also validates the tables against each other: spawn
colors, gray fill shades, and material wang colors must be pairwise
disjoint. Collisions are load errors that name both owners. Without
this check, priority order would silently shadow a material.

Tile compilation: each tile PNG compiles once at load into a flat
`[]u16` of material IDs. IDs `0xFFF8..0xFFFF` are reserved to mean
fill slots 0..7; the chunk blit resolves them through the biome's
8-entry fill table. The blit is one pass with one predictable
branch — near memcpy speed. Spawn markers compile into a short
per-tile list `{offset, kind}`, not into the cell array; markers
are rare and a per-cell spawn byte would double tile memory for
nothing. At n=64 and c=2, a compiled tileset is about 2 MiB.

### D6. Noise and uniform generators

- `generator = uniform` fills one material. Sky and deep rock use
  it, and it is the phase-1 walking skeleton.
- `generator = noise`: OpenSimplex2 from `core:math/noise`
  (`noise_2d(seed, coord)`), with our own ~10-line fBm octave
  loop (core has no fBm). Threshold picks cave vs solid; a second
  channel places ore veins. Parameters live in `biomes.txt`:

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

- Noise input is absolute world position; the seed offsets the
  noise domain. Same determinism rule as D4.
- Caveat, recorded: `noise_2d` is float math. Cross-platform
  bit-identity is not guaranteed. Wang biomes are pure integer and
  fully portable. If cross-platform identical worlds become a hard
  requirement, noise biomes switch to an integer value-noise built
  on `mix`; until then golden tests for noise biomes are pinned to
  one platform.

### D7. Tools: close the authoring loop, do not build a paint program

Painting pixels is solved by Aseprite and GIMP, and Noita shipped
that way. The gaps a solo dev actually hits are: producing a valid
template, staying on exact palette colors, keeping same-color edges
continuous, and seeing stitched results fast. Each gets a cheap,
dedicated answer. Both tools are thin shells over the game
package's own loader and generator, so the tools exercise the real
code path.

`tools/tilegen` (needed from P2, so it is built in P2):

- Writes an empty template PNG for a given sidecar config: stb slot
  layout, guide lines, and stb-style corner-color indicator marks
  on every slot edge, so the artist can see which edges must agree.
- Writes the palette as a file the editor imports (`.gpl` works in
  both Aseprite and GIMP): all material wang colors, the 8 gray
  fills, all spawn markers, each named.
- Writes the template as an **indexed PNG** using that exact
  palette. Painting in indexed mode makes off-palette colors and
  anti-aliased edges impossible — the two classic footguns.
- PNG **encoding** is not in Odin core (`core:image/png` decodes
  only). tilegen writes PNGs through `vendor:stb/image`
  (`stb_image_write`). This stays inside the vendor-library rule.

`tools/biomeview` (first version in P1, grows with each phase):

- Opens a `vendor:raylib` window, generates a region through the
  real pipeline, draws it with material display colors.
- Polls file modification times each frame (raylib has no file
  watcher) and regenerates on change: save in Aseprite, see the
  stitched biome in about a second.
- Overlays on toggle: chunk borders, herringbone lattice and corner
  colors, spawn markers, biome map regions.
- Click a pixel: material name, tile ID, and the tile's source
  rectangle in the template — a bad seam points back to the slot
  to fix.
- Load errors render in the window at the offending pixels, not
  only as console text.
- Reseed key. An in-tool pixel brush stays out unless the external
  editor loop proves slow in practice.

Continuity aid in the loader: corner mode implies every tile edge's
border pixels should depend only on its two endpoint corner colors.
The loader compares 1-pixel border strips of same-signature edges
and **warns** (not errors) on mismatch, listing the slots. This
catches "matching tile exists but the join looks wrong" early.

### D8. Testing

All tests run with `odin test src`, like the material tests.

- Unit: biome, tileset-sidecar, and spawn table parsing; RGBA-bytes
  to ARGB-u32 conversion; lattice class assignment incl. negative
  coordinates; tile slicing counts and sizes; paint-semantics
  mapping incl. every error case; cross-table color disjointness;
  template coverage validation.
- Determinism: same seed -> `mem.compare`-identical chunk cells and
  equal sorted spawn lists. Different chunk generation order ->
  identical world.
- Seam tests: adjacent same-biome chunks generated independently
  share identical border tiles and cells. Plus a biome-border case:
  clipping is stable and both sides are deterministic.
- Hash quality: the corner-color overlay in biomeview is the
  eyeball check; a unit test asserts `mix` passes a basic avalanche
  sanity check so lattice sampling shows no obvious period.
- Golden test: fixed seed + a small committed test tileset -> hash
  of the output region. Regenerate the golden hash only
  deliberately. Noise-biome goldens are platform-pinned (D6).

## The authoring workflow, end to end

1. Add a `[Tileset]` sidecar, run tilegen: template PNG + palette.
2. Open the template in Aseprite. Import the palette. Stay in
   indexed mode. No anti-aliasing, no color profiles.
3. Paint slots. Edge indicator marks show which edges must carry
   the same terrain profile. Convention: decide per corner color
   what its edges mean (for example color 0 = solid, color 1 =
   open passage at the edge midpoint, width ~n/4).
4. Save. biomeview regenerates and shows the stitched biome.
   Fix seams by clicking them to find the slot.
5. First ramp for real: c = 1 1 1 1 (2 tiles — everything matches
   everything) to prove the pipeline, then 2 2 2 2 (128 tiles at
   128x64 / 64x128) for the first real biome. That is a bounded,
   week-scale art task, not an open-ended one.

## Phases

Each phase ends green-tested and demo-able in biomeview.

- **P0 — Toolchain spike (half a day).** On a dev machine (this
  planning container has no Odin): `core:image/png` decodes RGBA
  and indexed PNGs; `vendor:stb/image` writes PNGs;
  `core:math/noise` runs; `vendor:raylib` opens a window, blits a
  texture, reads file mod times. Any failure here changes D7
  before code exists.
- **P1 — World skeleton + biomeview v0.** Chunk pool and store,
  biome table with `[Map]`, biome map loading, `uniform`
  generator. Demo: biomeview shows colored chunk regions matching
  `biome_map.png`, with hot reload of the biome map already
  working.
- **P2 — Herringbone core + minimal tilegen.** Sidecar parsing,
  template slicing, lattice + `mix` hashes, per-chunk generation
  with cross-border blitting, coverage validation. Minimal tilegen
  (template skeleton + guides — needed to make the test tileset).
  Determinism and seam tests. Demo: a c=1 then a 2-color test
  tileset stitching seamlessly across chunk borders.
- **P3 — Paint semantics.** wang_color in the cold table, gray
  fills, spawn table and markers, disjointness validation, load
  errors with positions, golden test. Demo: a tiny hand-made biome
  with fills re-skinned two ways from one tileset.
- **P4 — Author the first real biome.** A coalmine-alike at
  c = 2 2 2 2. This is its own phase because authoring is the
  riskiest unvalidated step, and it drives the tools: palette
  export, indexed template, edge indicator marks, border-strip
  warnings, click-to-slot. Budget about a week; if the loop feels
  slow, that is the trigger to consider in-tool painting.
- **P5 — Noise biomes.** fBm wrapper + tests, ore veins, sky and
  deep-rock biomes in the map. Demo: a biome map mixing wang,
  noise, and uniform biomes.
- **P6 — Pixel scenes.** PNG stamps with D5 semantics; random
  anchor markers in tiles plus a global fixed-position list. Demo:
  a set piece appearing intact across chunk borders.

## Open questions (still open on purpose)

1. Background layer timing: before or after P4? Painting the first
   real tileset without backgrounds means repainting cost later.
2. n = 64 default: revisit after P4 with real authoring experience.
3. Cross-platform float determinism (D6): does the game ever need
   identical worlds across platforms (seed sharing between
   friends)? If yes, plan the integer-noise swap before shipping
   noise biomes widely.

## Revision notes

Round 1 review: three independent adversarial reviews (algorithmic
correctness; Odin and performance; scope and pipeline). Main
changes made in response:

- Fixed the self-contradiction in D4: tile choice is now a pure
  per-lattice-cell hash; chunk-seeded PRNG streams are banned from
  worldgen entirely. (All three reviewers found this.)
- Added the missing biome-border rule: per-biome lattice scoping
  with hard clipping, plus a border seam test.
- Specified the lattice, per-class moduli, floored modulo, our own
  mixer, and the dropped repetition-reduction pass with its
  recorded upgrade path.
- Ran the combinatorics: c^6 per orientation; capped colors at 2;
  `vary` is the variety knob; n default cut to 64; fixed the wrong
  "few dozen tiles per chunk" arithmetic.
- PNG encoding hole closed: core decodes only; tilegen writes via
  `vendor:stb/image`; added encode to the P0 spike.
- Chunks became pooled POD behind pointers; spawns moved out of
  the chunk; determinism tests defined as `mem.compare`.
- Split `wang_color` from display `color` (cold table, hot struct
  unchanged) and added cross-table color disjointness validation.
- Resequenced tools: minimal tilegen into P2, biomeview from P1
  with hot reload; authoring a real tileset became its own phase
  (P4) as the riskiest step.
- Added authoring-loop defenses: indexed-PNG templates, exported
  named palette, edge indicator marks, border-strip continuity
  warnings, click-to-slot navigation, in-window load errors.
- Recorded non-goals (background layer with migration path, hard
  biome borders, persistence) and resolved three open questions
  (u16 cells; spawns outside chunks; raylib is fine — it is a
  vendor library).
