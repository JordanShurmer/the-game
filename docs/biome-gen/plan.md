# Plan: Biome Generation in Odin

Status: revision 5. The geometry is now derived and checked. See
"Revision notes" at the end.

This plan follows the research in `noita-research.md`.

## Terms

Three different things were all called "slot" in earlier
revisions. They are now separate:

- **Template slot**: one painted tile image in the template PNG.
- **Edge kind**: one of the 6 lattice edge classes in D3.
- **Fill slot**: one of the 8 gray shades that a biome maps to a
  material in D5.

## The ladder audit

The project rule is the ponytail complexity ladder:

1. Does this need to exist? If no, skip it.
2. Does the standard library do it? Use it.
3. Is there a native platform feature? Use it.
4. Is there an installed dependency? Use it.
5. Can it be one line? Make it one line.
6. Only then write the minimum that works.

Correctness, safety, and data loss are outside the "skip it"
calculus.

Cut on rung 1:

| Cut | Why | When it returns |
| --- | --- | --- |
| Spawn table and spawn store | Nothing consumes them. No entity system exists. | P6, with pixel scenes, which need anchor markers anyway. |
| Chunk pool and chunk store | Generation is pure and per region. A map of chunks caches a pure function for no consumer, and it leaks on every reseed. | With streaming. |
| Per-(biome, tileset) tile compilation | Premature. Revision 2 called the branch cheap and revision 3 reversed that. Neither measured. | If the P3 benchmark shows the branch costs more than the memory. |
| Procedural interior carver | The connect policy is a level-design decision with no local answer. Routing every port to the tile center also puts a visible junction in every tile. | Only if interior painting proves to be the bottleneck. |
| Avalanche test for `mix` | We copy splitmix64's finalizer with pinned constants. The test would assert a published result we did not derive. | Never. Determinism, seam, and golden tests already report a broken mixer. |

Kept, with the rung that justifies them:

- `core:image/png` decode (rung 2), `vendor:stb/image` encode
  (rung 4), `vendor:raylib` (rung 4), `core:math/noise` (rung 2),
  raygui if bundled (rung 4, verify in P0).
- `mix`, our own hash (rung 6). `core:math/rand` is unusable here:
  its algorithm may change between compiler releases, which would
  regenerate every world. This is a correctness boundary.
- One shared config tokenizer (rung 5). See D9.
- One tool binary with modes, not several binaries.

Restored, because revision 3 cut them wrongly:

- **Template dimension validation.** This is memory safety. The
  sidecar and the PNG are separate files with separate edits and
  hot reload. If they disagree, slot slicing reads out of bounds.
  Hard load error, always.
- **Template slot coverage and the seam lint.** Composition
  arrives in P4, but P2 and P3 run on hand-made templates, and
  hand editing stays legal. Both checks run on real art.

## Goals

1. Generate an unbounded 2D pixel world from a seed.
2. A small biome-map image controls the world layout.
3. Biomes generate from authored herringbone wang tilesets.
4. Colors in tiles encode materials and biome fills.
5. Any region generates alone, in any order, deterministically.
6. Authoring is fast, and mistakes are reported at load.

Non-goals: background wall layer (deferred; migration is a
parallel `background` array plus a companion `_bg.png` per
tileset); spawn points and entities until P6; biome blending, so
borders are hard cuts; chunk persistence and streaming;
depth-based variation; world edges; parallel worlds.

## Design decisions

### D1. World grid, regions, and chunks

- The world is an unbounded grid of cells. A cell holds a material
  ID (`u16`). 256 materials fit in `u8`, but the saved memory has
  no use here.
- `Material_ID :: distinct u16` indexes the material table. It does
  not exist in `material.odin` yet. P1 adds it.
- **A region is the unit of biome ownership.** `REGION_SIZE :: 512`
  world cells. One biome-map pixel is one region. This is fixed and
  independent of how generation is cut into pieces.
- **A chunk is only a cut.** It is how much the caller asks for at
  once. Generation writes into a caller-owned `[]Material_ID` with
  an explicit width, height, and world origin. There is no chunk
  struct and no chunk store until streaming exists.
- Generation signature intent:
  `generate(dest: []Material_ID, w, h: int, world_origin: [2]i32,
  seed: u64)`. It iterates the regions that overlap the rectangle
  and clips each. The caller does not split by region.
- Future simulation needs per-cell flags, shade, and sparse
  velocity. Those become parallel arrays, not a fat per-cell
  struct. Most cells are static, so a fat cell would move unused
  bytes through cache.

**On the chunk-size control.** The owner asked for a chunk-size UI
control. It is kept, and it is now honest, because regions and
chunks are separate. Chunk size changes only how the same world is
cut into pieces. It changes seam behavior and per-call cost. It
does not change the terrain. `n` and `REGION_SIZE` change terrain.
Revision 4 claimed chunk size never changes terrain while also
saying one map pixel is one chunk; those two statements
contradicted each other. Separating regions from chunks removes the
contradiction.

### D2. Biome map and biome table

- `data/biome_map.png`, decoded with `core:image/png`. One map
  pixel is one region.
- `data/biomes.txt` uses the shared format and tokenizer (D9):

```
[Map]
image         = data/biome_map.png
origin_pixel  = 35 12       # this pixel is region (0, 0)
biome_off_map = Deep_Rock   # default outside the image
biome_above   = Sky         # optional; see rule below
```

`biome_above` applies to any region above the image, including a
region that is also outside the image to the left or right. All
other outside regions use `biome_off_map`.

```
[Coalmine]
color     = 0xFFD57917      # key color in biome_map.png
generator = wang            # wang | noise | uniform
tileset   = data/tiles/coalmine.png
fill_0    = Rock            # gray shade 0 -> material
fill_1    = Dirt
fill_2    = Air
```

- All data files use `0xAARRGGBB`, as in `materials.txt`. The PNG
  decoder gives RGBA bytes. One tested procedure converts them.
- A future `cells_per_pixel` key in `[Map]` changes `REGION_SIZE`
  per map, for finer biome shapes.

### D3. The herringbone lattice, derived

Revision 4 stated this geometry but got the vertical half wrong.
The tables below are derived from `class = (i - j + 1) & 3` and
checked by enumeration.

**Corner points per tile.** Every tile has exactly 6 corner points
and 6 boundary segments. Each segment is exactly `n` long, so the
perimeter is `6n` in both orientations. The long side is split by a
middle point.

- Horizontal tile, `2n x n`: `a` top-left, `b` top-middle,
  `c` top-right, `d` bottom-left, `e` bottom-middle,
  `f` bottom-right.
- Vertical tile, `n x 2n`: `a` top-left, `b` middle-left,
  `c` bottom-left, `d` top-right, `e` middle-right,
  `f` bottom-right.

**Edge kinds.** A horizontal segment runs class `t` to `t+1`. A
vertical segment runs class `t` to `t-1`. Only 6 of the 8 possible
class pairs are ever tile boundaries:

| Direction | Boundary class pairs | Never a boundary |
| --- | --- | --- |
| Horizontal | (0,1), (1,2), (2,3) | (3,0) |
| Vertical | (1,0), (0,3), (3,2) | (2,1) |

The two never-boundary pairs are the lines that bisect a tile:
h(3,0) bisects a vertical tile, and v(2,1) bisects a horizontal
tile.

**Corner classes per orientation.** Enumeration shows only one
origin class is legal for each orientation. A horizontal tile has
origin class 1. A vertical tile has origin class 0.

| Orientation | `a` | `b` | `c` | `d` | `e` | `f` |
| --- | --- | --- | --- | --- | --- | --- |
| Horizontal | 1 | 2 | 3 | 0 | 1 | 2 |
| Vertical | 0 | 3 | 2 | 1 | 0 | 3 |

This table sets the radix of each digit in the slot index, so it
must be in the source, not inferred.

**Edges belong to the lattice, not to a tile.** A horizontal tile's
bottom-left segment is a vertical tile's top edge. Boundary art
must therefore be keyed on the lattice edge and shared across tile
orientations. Keying per tile orientation would produce mismatched
seams on the most common seam in the tiling.

**Lattice points are T-junctions.** Every lattice point has four
incident n-grid segments. Three are tile boundaries. The fourth is
interior to a tile, so the artist paints it as interior, not as a
stub. Every point joins exactly 3 tiles:

| Class | Boundary arms | Interior arm |
| --- | --- | --- |
| 0 | right h(0,1), up v(1,0), down v(0,3) | left |
| 1 | left h(0,1), right h(1,2), down v(1,0) | up |
| 2 | left h(1,2), right h(2,3), up v(3,2) | down |
| 3 | left h(2,3), up v(0,3), down v(3,2) | right |

Each edge kind appears exactly twice, once per endpoint.

**Slot counts.** From the corner class table, with per-class color
counts `nc[0..3]`:

- Horizontal: `nc1 * nc2 * nc3 * nc0 * nc1 * nc2`
- Vertical: `nc0 * nc3 * nc2 * nc1 * nc0 * nc3`

At uniform `c` both give `c^6`, which is why revision 4's wrong
vertical formula passed unnoticed at `1 1 1 1` and `2 2 2 2`.

**Per-class counts are the art-cost ramp.** This is why they stay:

| `colors` | Horizontal | Vertical | Total |
| --- | --- | --- | --- |
| 1 1 1 1 | 1 | 1 | 2 |
| 2 1 1 1 | 2 | 4 | 6 |
| 2 2 1 1 | 8 | 8 | 16 |
| 2 2 2 1 | 32 | 16 | 48 |
| 2 2 2 2 | 64 | 64 | 128 |

Which classes are raised matters, not only how many. Raising two
classes costs 16 slots for the pairs {0,1}, {0,2}, {1,3}, {2,3},
and 20 slots for {0,3} and {1,2}.

**Our own slot layout.** We do not keep stb compatibility. We write
the slicer either way, and no stb-authored or Noita-authored asset
could load here. The layout is: a horizontal block, then a vertical
block. Inside a block, the index is mixed-radix. The digits are the
corner colors in the order `a,b,c,d,e,f`, each with the radix given
by its class in the corner class table. `variant` is the most
significant digit, with radix `vary`, so each orientation block
repeats `vary` times.

One procedure,
`slot_rect(colors: [6]u8, orientation, variant) -> Rect`, lives in
the game package. The engine and the tool both call it. A unit test
pins known indices.

**Tileset sidecar:**

```
# data/tiles/coalmine.txt
[Tileset]
n      = 64
colors = 2 2 1 1   # per corner class
vary   = 2         # interior alternatives per template slot
```

- Expected template slot count is `(horizontal + vertical) * vary`.
  The loader hard-errors if the PNG dimensions disagree with `n`,
  `colors`, and `vary`, and it reports both sizes. Omitting `vary`
  here was a revision 4 error that would have made a memory-safety
  check compute the wrong size.
- A template slot whose pixels are all alpha 0 is a load error. An
  all-Air tile is legal art, so the artist marks it with an
  explicit Air wang color rather than leaving it blank.
- `n` and `chunk_size` need no relation. Alignment
  (`chunk_size %% n == 0`) is a preference that reduces partial
  tiles. Correctness comes from clipping, so a tile that meets 4
  chunks uses the same code path.

### D4. Determinism without neighbor regions (the core mechanism)

Verified sound across four review rounds. stb generates a whole map
at once: it pre-assigns random corner colors, then picks a matching
tile per cell. We keep that structure and replace both random
streams with position hashes, so any region computes any lattice
value locally and neighbors agree by construction.

- **Corner colors.** `color(p) = mix(seed, p.x, p.y, SALT_CORNER)
  %% nc[class(p)]`, with `p` in n-units and floored modulo.
- **Tile choice.** The six corner colors and the variant index
  select the image through `slot_rect`. The variant is
  `mix(seed, c.x, c.y, SALT_TILE) %% vary`. The cell ID is the
  tile's origin corner in n-units. Orientation is a pure function
  of position: class 1 points are horizontal tile origins, and
  class 0 points are vertical tile origins.
- **`mix`** is splitmix64's finalizer with constants copied and
  pinned in our source. The input encoding is documented and
  tested: `seed` as little-endian `u64`, then `x` and `y`
  sign-extended from `i32` to `u64`, then the salt.
- **One enumeration procedure.** `tiles_overlapping(rect, n)` is an
  iterator over a caller-held state struct, not a returned slice,
  so generation allocates nothing. It yields origin, orientation,
  and overlap sub-rectangle. The engine and the tool both use it.
- **No PRNG streams in worldgen.** Draw order differs per call, so
  a stream would break seams. Every random-looking decision is a
  position hash with its own salt.
- **Biome borders.** The lattice, tileset, and hashes are scoped
  per biome. A region generates from its own biome only and never
  reads a neighbor, because it writes only inside its own
  rectangle. Clipping at a biome border uses the same code path as
  clipping at the requested rectangle, so no cell is left
  undefined.
- **Dropped: stb's repetition-reduction pass.** It mutates the
  color grid in sequence, which cannot run per region. **There is
  no repetition mitigation at present.** The first control is
  `vary`. The recorded upgrade is a hash-local change: alter a
  corner when its fixed-size neighborhood of base hash colors
  matches a repeat pattern. That stays deterministic and order
  free.

### D5. Paint semantics

Each material gets a `wang_color`: the color that represents it in
authored PNGs. It defaults to the display `color` but is a separate
value in the cold parallel table, so display colors stay tunable
without repainting art, and two materials may share a display color
but never a paint key. `Material_Table` gains `wang_colors: []u32`.
The hot 32-byte `Material` struct does not change.

Priority order per template pixel:

1. Alpha 0 gives Air.
2. A gray fill shade gives fill slot 0..7. These are exactly the 8
   values `0xFF101010, 0xFF202020, ... 0xFF808080`, step `0x10` per
   channel. Other grays stay available as wang colors.
3. A material `wang_color` gives that material.
4. Anything else is a load error that reports the pixel position.

Color keys must have alpha `0xFF`. Air is the exception, covered by
rule 1.

Validation at load: gray fill shades and material wang colors must
be disjoint, and a collision names both owners. Every biome must
define every fill slot that its tileset uses.

**Compilation and the blit.** Each template slot compiles once into
a flat `[]u16`. Fill slots compile to reserved IDs
`0xFFF8..0xFFFF` and resolve during the blit through the biome's
8-entry table. That is one predictable branch per cell. Revision 3
replaced this with per-(biome, tileset) resolved copies to reach a
pure memcpy. That is reverted as premature: it multiplies memory by
the number of biomes sharing a tileset, adds a bind cache and an
invalidation path on hot reload, and was never measured. P3
measures it. Target: 1 ms per 512x512 chunk at n=64.

### D6. Noise and uniform generators

- `generator = uniform` fills one material. It is the P1 skeleton.
- `generator = noise` uses OpenSimplex2 from `core:math/noise` with
  a short fBm loop, because core has no fBm. A threshold picks cave
  or solid, and a second channel places ore veins. Parameters live
  in `biomes.txt`: `frequency`, `octaves`, `threshold`, `solid`,
  `open`, `vein`, `vein_freq`, `vein_cut`.
- Noise input is absolute world position. The seed offsets the
  domain.

**Open question, reopened.** Revision 3 closed cross-platform
determinism by shipping one artifact per platform with
`when ODIN_OS` checks. That does not address the risk. Float
divergence comes from FMA contraction, x87 versus SSE, libm
differences, and optimization level. A per-OS build addresses none
of them, and per-platform artifacts are the seed-sharing failure
case rather than a defense against it. Noita players share seeds.
Exposure is limited to P5 noise biomes, because wang biomes use
integer math. The alternative is an integer value-noise built on
`mix`, which is a small amount of code. **Decide before P5 ships.**

### D7. forge: one tool, modes added when earned

`tools/forge` is a single `vendor:raylib` binary. It shares one
window, one palette renderer, one loader, and one generator. It is
a thin shell over the game package, so it exercises the real code
path. Widgets come from raygui if the distribution bundles it,
verified in P0.

Common to all modes: hot reload by polling file modification times,
because raylib has no file watcher; load errors drawn in the window
at the offending pixels, not only in the console.

Revision 3 shipped three modes at once and removed revision 2's
condition on in-tool painting. The condition is restored: **Preview
is built first. A painting mode is built when the phase that needs
it arrives.**

**Preview mode (P1).** Generates a region through the real pipeline
and draws it with material display colors. Overlays on toggle:
region borders, chunk borders, the lattice with corner colors and
classes, biome map regions. Click a pixel to see the material name,
tile ID, and source template slot, so a bad seam identifies the
slot that produced it. Steppers for `n` and chunk size, with the D1
note that chunk size changes only the cut. Reseed key.

**Tileset mode (P4).** The painting mode, built when authoring
starts. Its purpose is the part an image editor cannot do, which is
applying the constraint rules.

- Paint with squares that map to single pixels, at a chosen zoom.
- The palette is constrained by construction: material wang colors
  by name, and the 8 gray fills labeled with the material each
  currently resolves to. Off-palette colors and anti-aliased edges
  become impossible without relying on editor settings.
- Info panel: template slot index, its six corner colors and their
  classes, slot counts, and memory cost of the current `n`,
  `colors`, and `vary`.
- **Composition, as a scaffold.** The artist paints a boundary
  vocabulary, and forge stamps it into every template slot as a
  starting point:
  - **Edge strips**, keyed on
    `(edge_kind, color_at_t_end, color_at_other_end)`. The first
    endpoint is always the class-`t` end, where the segment runs
    `t` to `t+1` horizontally or `t` to `t-1` vertically. Strips
    are stored left to right and top to bottom. Ordering by class
    number instead would place the first endpoint at the bottom for
    some vertical kinds and at the top for others, which silently
    mirrors art. At uniform `c` there are `6c^2` strips, which is
    **24 at c=2**, not the 8 that revision 3 claimed. Strips are
    shared across tile orientations.
  - **Corner hubs**, one per class and color, shaped as the
    3-armed junctions in the arm table above.
  - **The join rule.** A hub owns a fixed `r`-pixel radius at the
    lattice point and stamps after the strips. A strip's
    cross-section at each end must be a function of that endpoint's
    `(class, color)` alone. Without that rule, `4c` hubs cannot
    serve `6c^2` strips. forge pre-fills each strip's two end
    cross-sections from the incident hubs when the artist opens
    that strip.
  - Strip width `w` and hub radius `r` live in forge's own file,
    not in the engine sidecar. The engine never composes, so it has
    no use for them.
  - Composition writes a normal template PNG. **The engine format
    does not change and gains no new failure mode.**
- **What composition does and does not provide.** It makes
  boundaries cheap and consistent, and it writes every template
  slot, so a fresh template is never under-covered. It provides no
  structural guarantee, because hand edits stay legal. It does not
  remove the `c^6` cost from interiors: each slot's interior must
  connect its open boundary ports, and the number of distinct
  connectivity cases is again one per color combination. Interiors
  are painted, not carved.
- **Composition is more repetitive than hand painting.** At n=64
  and c=2, a 512-cell chunk holds 32 tiles, 96 lattice edges, and
  64 lattice points, drawn from 24 strips and 8 hubs. Each hub
  appears about 8 times per chunk, pixel identical, everywhere in
  the world. `vary` cannot correct this: stb variants share corner
  colors, so variants may differ only in interiors, never on edges.
  The strip and hub vocabulary is a lower limit.
- **Therefore compose first, then paint detail.** Composition is a
  scaffold, not a finished product. The artist paints detail into
  the slots that appear most often, and the seam lint reports any
  detail that breaks a seam.
- **Re-composition must not destroy hand work.** Data loss is
  outside the skip-it calculus. Composition writes the template
  only when the template is older than its parts. Otherwise it
  stops and reports both times. An explicit `--force` overwrites.

**World Map mode (after P4).** The owner asked for this, and it is
worth building, but not first: it is the largest mode by code and
the smallest by risk, and the first biome map is a few pixels. It
draws the map as large squares, one per region, with a palette of
biomes by name, and an info panel showing region coordinate, biome,
generator, and the world rectangle covered. Until then forge
exports a `.gpl` palette that Aseprite and GIMP both import, so the
map can be painted there with named colors.

### D8. Testing

All tests run with `odin test src` from the repository root,
because the tests read `data/` by relative path.

- Unit: the config tokenizer, including unknown keys and malformed
  lines; RGBA to ARGB conversion; `class(p)` including negative
  coordinates; the edge kind table and the arm table; the corner
  class table per orientation; `slot_rect` on pinned indices,
  including variants; slot count formulas against the ramp table;
  `tiles_overlapping` counts, orientations, and sub-rectangles;
  paint semantics and every error case; color disjointness; fill
  coverage; template dimension mismatch; all-alpha-0 slot.
- Determinism: one seed gives `mem.compare`-identical output. A
  different call order gives an identical world.
- Seam tests: two adjacent rectangles generated independently share
  identical border cells. A biome-border case checks that clipping
  is stable.
- **Seam lint.** For each edge kind and endpoint color pair, every
  template slot that carries that edge must present the same
  `n`-long Air mask on the line of pixels next to the edge. This
  covers both sides of the seam, both orientations, and every
  variant. The mask is the property that makes seams continuous.
  Revision 4 asked instead for identical pixels across
  orientations, which is impossible: two tiles that share a lattice
  edge own disjoint pixels, one on each side. The mask version
  needs no strip width, runs at P2 on hand art with only the
  provisional paint mapping, and enforces the rule that variants
  differ only in interiors. This procedure lives in the game
  package and runs from both tests and forge.
- **Dead-end warning (forge only).** For each template slot, every
  boundary port's Air component must touch at least one other
  boundary port. This catches caves that stop at a tile center.
  Revision 4 asked for "the ports it should reach", which needs the
  same connect policy that justified cutting the carver. This
  version needs no policy. It is a warning in `tools/forge`, not a
  test, because a sealed pocket is often deliberate.
- Golden test: a fixed seed and a committed tileset give a known
  hash. Regenerate it only on purpose. It is the only check against
  silently regenerating every player's world.
- Performance: a benchmark prints generation time. It does not
  assert, because a loaded machine would fail it for unrelated
  reasons. 1 ms per 512x512 chunk at n=64 is a recorded target.

### D9. One config format, one tokenizer

`materials.txt`, `biomes.txt`, and the tileset sidecar share one
format. P1 extracts the section, key, value, and comment tokenizer
from `material_loader.odin` into one procedure that all three use.

This is also a bug fix. The current key switch has no default case,
and `material_loader.odin:61` skips malformed lines with
`if eq < 0 do continue`. A typo such as `tilesett = ...` would load
a biome with no tileset and no error, which is a wrong world with
no message. The shared tokenizer reports unknown keys and malformed
lines with the file name and line number. Silent config failure is
a correctness problem. All twelve keys in the current
`data/materials.txt` are handled, so the change does not break it.

## The authoring workflow, end to end

1. Write a `[Tileset]` sidecar. Start at `colors = 1 1 1 1`, which
   is 2 template slots and proves the pipeline.
2. Paint the boundary vocabulary in forge Tileset mode. forge
   composes every template slot.
3. Open Preview. The stitched world appears at once.
4. Paint detail into weak slots. The seam lint and the dead-end
   warning run on every reload and mark problems in place.
5. Raise `colors` one class at a time: `2 1 1 1` is 6 slots,
   `2 2 1 1` is 16, `2 2 2 1` is 48, `2 2 2 2` is 128. Stop where
   the variety is good enough for the art budget. Prefer the class
   pairs that cost 16 over {0,3} and {1,2}, which cost 20.

## Phases

Each phase ends with passing tests and a demonstration in forge.

- **P0 — Toolchain spike, half a day.** On a machine with Odin,
  because this container has none. Verify: `core:image/png` decodes
  RGBA and indexed PNGs; `vendor:stb/image` writes PNGs;
  `core:math/noise` runs; `vendor:raylib` opens a window, blits a
  texture, and reads file modification times; whether raygui ships
  with the distribution. Any failure changes D7 before code exists.
- **P1 — World skeleton, forge Preview, shared tokenizer.**
  `Material_ID`, the D9 tokenizer with its error reporting, the
  biome table with `[Map]`, biome map loading, the `uniform`
  generator, and generation into a caller-owned slice. Demo:
  Preview shows biome regions from `biome_map.png` with hot reload.
- **P2 — Herringbone core.** Sidecar parsing with dimension
  validation, `class`, the corner class tables, `slot_rect`, `mix`,
  `tiles_overlapping`, template slicing, generation with
  cross-border blitting, slot coverage, and the seam lint.
  Provisional paint mapping: alpha 0 gives Air, and any other pixel
  gives one test material. Determinism and seam tests. Demo:
  `1 1 1 1` then `2 2 1 1` debug tilesets stitching seamlessly.
- **P3 — Paint semantics.** `wang_color` in the cold table, gray
  fills, disjointness, fill coverage, load errors with positions,
  the golden test, and the blit benchmark that settles D5's open
  compilation question. Demo: one tileset re-skinned by two biomes.
- **P4 — forge Tileset mode and the first real biome.** The
  constrained palette, the info panel, edge strips, corner hubs,
  the join rule, the compositor with its overwrite rule, and the
  dead-end warning. Then author a coalmine-like biome, raising
  `colors` as the art allows. Authoring is the riskiest unproven
  step, so the phase ends when a real biome looks right in Preview.
- **P5 — Noise biomes.** The fBm wrapper and its tests, ore veins,
  and sky and deep-rock biomes. Settle the D6 question first.
- **P6 — Pixel scenes and spawn markers.** PNG stamps with D5
  semantics, anchor markers, and a global fixed-position list. The
  marker mechanism cut from the earlier plan returns here.
- **Later — World Map mode**, then the background layer, streaming,
  the chunk store, and the chunk pool.

## Revision notes

Revision 5 (arithmetic and definitions). Corrected the vertical
slot formula: the vertical corner classes are (0,3,2,1,0,3), so the
count is `nc0*nc3*nc2*nc1*nc0*nc3`. Revision 4's version implied a
v(1,2) boundary, which the edge kind table forbids. The error was
invisible at uniform colors and wrong at the recommended ramp.
Corrected the ramp table to 2, 6, 16, 48, 128, and added the cost
of each class pair. Added the corner class table per orientation,
which sets the radix of every slot index digit. Gave `vary` an
address: `slot_rect` takes a variant, `vary` is the most
significant digit, and the dimension check includes it. Separated
regions from chunks, which removes the contradiction between D1 and
D2 and makes the chunk-size control honest. Redefined the seam lint
as an Air mask on the line next to the edge, because the previous
wording asked two tiles to share pixels they do not own. Reduced
the connectivity check to a policy-free dead-end warning in forge.
Added the strip and hub join rule, and keyed strips by segment
direction. Defined slot coverage. Moved `w` and `r` out of the
engine sidecar. Noted that a lattice point has four incident
segments, three of them boundaries. Stated the generate signature
intent. Separated the three meanings of "slot". Removed idioms and
metaphors for Simplified Technical English.

Revision 4 (correcting revision 3). Recorded that revision 3
overreached. Verified the herringbone geometry against the stb
source and specified it. Corrected the composition model: the
premise that edge pixels depend only on endpoint colors is false as
a property of corner mode; the strip count is `6c^2` keyed on
lattice edges; composition is a scaffold, does not remove the `c^6`
interior cost, and increases repetition. Restored dimension
validation, slot coverage, and the seam lint. Cut the interior
carver, the chunk store, per-pair compilation, and the avalanche
test. Added D9. Made `tiles_overlapping` an iterator. Made the
benchmark print instead of assert. Reopened the cross-platform
question.

Revision 3. Ladder audit; cut spawns and the pool; added forge and
composition. Substantially corrected above.

Revision 2. Provisional paint mapping for P2; corrected per-chunk
tile counts; pinned the tile-choice hash input; made gray fills
exactly 8 values; required alpha `0xFF`; added fill coverage.

Revision 1 (three adversarial reviews). Fixed a self-contradiction
where tile choice used a chunk-seeded PRNG, which broke the seam
guarantee; added per-biome lattice scoping; specified per-class
moduli and floored modulo; ran the `c^6` combinatorics; closed the
PNG encode hole with `vendor:stb/image`; split `wang_color` from
display `color`.
