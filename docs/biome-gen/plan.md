# Plan: Biome Generation in Odin

Status: revision 7. The geometry is now derived and checked. See
"Revision notes" at the end.

This plan follows the research in `noita-research.md`.

## Terms

Three different things were all called "slot" in earlier
revisions. They are now separate:

- **Template slot**: one painted tile image in the template PNG.
- **Edge kind**: one of the 6 lattice edge kinds in D3.
- **Fill slot**: one of the 8 gray shades that a biome maps to a
  material in D5.
- **Paint class**: what one template pixel compiles to. It is Air,
  a fill slot 0..7, or a material ID. It is biome independent.

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
- **A region is the unit of biome ownership.** One biome-map pixel
  is one region. The default is 512 world cells, and the `[Map]`
  key `cells_per_pixel` overrides it per map. Region size is
  independent of how generation is cut into pieces, but it is a
  terrain input, so the golden test pins it.
- **A chunk is only a cut.** It is how much the caller asks for at
  once. Generation writes into a caller-owned `[]Material_ID` with
  an explicit width, height, and world origin. There is no chunk
  struct and no chunk store until streaming exists.
- Generation signature intent:
  `generate(dest: []Material_ID, w, h: int, world_origin: [2]i32,
  seed: u64)`. It iterates the regions that overlap the rectangle
  and clips each. The caller does not split by region. It checks
  `len(dest) >= w * h`.
- **All world-to-lattice and world-to-region conversion uses
  floored division**, not Odin's `/`, which truncates toward zero.
  Without this, cells -511..-1 land in region 0 instead of region
  -1, and the lattice shifts by one across both axes at the origin.
  Every region with a negative coordinate is affected, so a seam
  test straddles the origin.
- Future simulation needs per-cell flags, shade, and sparse
  velocity. Those become parallel arrays, not a fat per-cell
  struct. Most cells are static, so a fat cell would move unused
  bytes through cache.

**On the chunk-size control.** The owner asked for a chunk-size UI
control. It is kept, and it now matches what it does, because
regions and chunks are separate. Chunk size changes only how the
same world is cut into pieces. It changes seam behavior and
per-call cost. It does not change the terrain. `n` and region size
change terrain.

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
  D9 item 6 explains why this literal needs explicit prefix
  handling.
- `cells_per_pixel` in `[Map]` sets the region size, default 512.

**Validation.** The sidecar got required keys and ranges in D3, and
every template pixel gets an error in D5. The biome table and the
map need the same treatment, or the most likely authoring mistakes
stay silent. All of these are hard load errors:

- **A map pixel whose color matches no biome key**, reported with
  the pixel position and its color. This is the most likely
  mistake, because World Map mode arrives after P4 and the interim
  workflow paints the map in an image editor, where one soft-brush
  pixel or one wrong channel produces an unmatched color. D5 rule 4
  already does this for template pixels.
- **Required biome keys**: `color` and `generator`. A `wang` biome
  also requires `tileset`. A section with no `color` never matches
  any pixel and is silently dead, while the regions painted for it
  hit the unmatched-color error above. A `noise` biome requires the
  D6 parameters.
- **Name cross-references resolve**: `biome_off_map`,
  `biome_above`, every `fill_N`, and the noise material names must
  name an existing biome or material. The D9 rule covers unknown
  enum names, not unresolved table lookups.
- **Names and key colors are unique**: no duplicate biome section
  name, no duplicate material name, no duplicate biome key color.
  A duplicate key color would also make two biomes generate
  identically, because the color is the `biome_salt` in D4.
- `Map` is a reserved section name. A biome may not use it.

**The biome key color is a terrain input**, not only a lookup key,
because D4 uses it as `biome_salt`. Changing it reshapes every
region of that biome. Treat it as pinned once art ships, and record
it among the golden test's inputs.

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

Counts below are **per variant**. Painted images are the total
multiplied by `vary`.

| `colors` | Horizontal | Vertical | Total per variant |
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
could load here. The layout below is ours, and it must be written
down because it becomes the on-disk art format.

Each orientation forms a 2D grid of slots. The six corner digits
split into three that index the column and three that index the
row. Each digit's radix is the count of its own corner class, taken
from the corner class table above:

| Orientation | Column digits (`a,b,c`) | Row digits (`d,e,f`) |
| --- | --- | --- |
| Horizontal (top row, then bottom row) | radices `nc1, nc2, nc3` | radices `nc0, nc1, nc2` |
| Vertical (left column, then right column) | radices `nc0, nc3, nc2` | radices `nc1, nc0, nc3` |

Within each group the first corner is the most significant digit.
The column and row counts multiply to the slot counts above, which
is the check that the split is correct.

- Horizontal block: `nc1*nc2*nc3` columns by `nc0*nc1*nc2` rows,
  each cell `2n` by `n`.
- Vertical block: `nc0*nc3*nc2` columns by `nc1*nc0*nc3` rows, each
  cell `n` by `2n`.
- The image holds, for each variant in order, the horizontal block
  and then the vertical block, stacked downward. There is no
  padding.

Image size follows, and this is the formula the dimension check
uses:

```
width  = max(2n * nc1*nc2*nc3, n * nc0*nc3*nc2)
height = vary * (n * nc0*nc1*nc2 + 2n * nc1*nc0*nc3)
```

At `n = 64` and `vary = 1`: `colors = 2 2 2 2` gives 1024 by 1536,
and `colors = 2 2 1 1` gives 256 by 768.

Pixels outside every slot rectangle are ignored: compilation, slot
coverage, and D5 rule 4 all skip them. Whenever `nc0` differs from
`2 * nc1` one block is narrower than the image, so at the
recommended `2 2 2 2` a 512 by 1024 area is unused. Without this
rule an implementer who walks the whole decoded image, rather than
the slot rectangles, would turn an editor's background color into a
load error.

One procedure,
`slot_rect(cfg: Tileset_Config, corner_colors: [6]u8, orientation,
variant) -> Rect`, lives in the game package. It needs `cfg`
because the radices are the per-class counts and the geometry comes
from `n`. The `cfg` field holding those counts is named
`class_counts`, not `colors`, so it cannot be confused with the six
corner colors. The engine and the tool both call it. A unit test
pins known indices at uniform and non-uniform counts, including one
case where the vertical block is wider than the horizontal block,
which is the only case that exercises the `max()` in the
non-obvious direction.

**Tileset sidecar:**

```
# data/tiles/coalmine.txt
[Tileset]
n      = 64
colors = 2 2 1 1   # per corner class
vary   = 2         # interior alternatives per template slot
```

- Expected template slot count is `(horizontal + vertical) * vary`.
  The loader hard-errors if the PNG dimensions disagree with the
  formula above, and it reports both sizes. Omitting `vary` here
  was a revision 4 error that would have made a memory-safety check
  compute the wrong size.
- **Template slot coverage**: a template slot whose pixels are all
  alpha 0 is a load error. An all-Air tile is legal art, so the
  artist marks it with an explicit Air wang color rather than
  leaving it blank.
- **Required keys and ranges.** `n`, `colors`, and `vary` must be
  present. `n >= 1`, `vary >= 1`, and each `colors` entry in 1..8.
  A zero would divide by zero in `%% nc[class(p)]` or `%% vary`.
  The upper bound is about art cost and image size, not stb
  compatibility, which D3 disclaims: uniform `c = 8` at `n = 64`
  needs a template over 65000 pixels wide. Each violation is a hard
  load error naming the file and line.
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

- **Corner colors.** `color(p) = mix(seed, biome_salt, p.x, p.y,
  SALT_CORNER) %% nc[class(p)]`, with `p` in n-units and floored
  modulo.
- **Tile choice.** The six corner colors and the variant index
  select the image through `slot_rect`. The variant is
  `mix(seed, biome_salt, c.x, c.y, SALT_TILE) %% vary`. The cell ID
  is the tile's origin corner in n-units. Orientation is a pure
  function of position: class 1 points are horizontal tile origins,
  and class 0 points are vertical tile origins.
- **`biome_salt` is the biome's key color from `biomes.txt`.** Two
  biomes that share a tileset then differ in shape, instead of
  being identical everywhere in the world. The salt must never come
  from the biome's index in the table: adding a biome would
  renumber the rest and regenerate every world, which is the
  failure the golden test exists to catch. Key colors are already
  unique, because D2 requires it.
- **`mix`** copies splitmix64's finalizer, with its constants
  pinned in our source. It folds its inputs one at a time:
  `h = seed; for v in inputs { h = finalize(h ~ v) }`. Inputs are
  `u64` values in a fixed order, with `x` and `y` sign-extended
  from `i32`. Nothing is serialized to bytes, so endianness does
  not apply. A unit test pins the output for known inputs.
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
8-entry table. The loader asserts the material table holds fewer
than `0xFFF8` entries, so a material ID can never collide with a
reserved ID. That is one predictable branch per cell. Revision 3
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
region borders, chunk borders, biome map regions, and, from P2, the
lattice with corner colors and classes. Click a pixel to see the
material name and, from P2, the tile ID and source template slot,
so a bad seam identifies the slot that produced it. A chunk-size
stepper, with the D1 note that chunk size changes only the cut.
Reseed key.

`n` is shown, not edited. From P2 the loader hard-errors whenever
the PNG dimensions disagree with `n`, so a stepper could only
produce a load error at every value except the sidecar's. Changing
`n` means editing the sidecar and re-composing.

**Tileset mode (P4).** The painting mode, built when authoring
starts. Its purpose is the part an image editor cannot do, which is
applying the constraint rules.

- Paint with squares that map to single pixels, at a chosen zoom.
- The palette is constrained by construction: material wang colors
  by name, and the 8 gray fills labeled with the material each
  currently resolves to. The palette prevents off-palette colors
  and anti-aliased edges. The artist does not need to configure the
  image editor.
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
  coverage; template dimension mismatch; all-alpha-0 slot; missing
  required keys and out-of-range values; duplicate biome key color.
- Negative fixture for the seam lint: a tileset with one
  deliberately broken boundary line must fail it. Without this, a
  lint that always reports "clean" looks identical to a correct
  one.
- Determinism: one seed gives `mem.compare`-identical output. A
  different call order gives an identical world.
- Seam tests: two adjacent rectangles generated independently share
  identical border cells. A biome-border case checks that clipping
  is stable. A case straddling the world origin checks the floored
  division in D1.
- **Seam lint.** For each edge kind and endpoint color pair, every
  template slot that carries that edge must present the same
  `n`-long sequence of **paint classes** on the line of pixels next
  to the edge. This covers both sides of the seam, both
  orientations, and every variant. Read the line along increasing x
  for horizontal segments and increasing y for vertical segments,
  which matches the class-`t`-end rule used for strips. Only the 6
  edge kinds are linted; the tile-interior lines h(3,0) and v(2,1)
  are not edges and are excluded by definition.
  - Revision 4 asked for identical pixels across orientations,
    which is impossible: two tiles sharing a lattice edge own
    disjoint pixels, one on each side.
  - Revision 5 asked for an Air mask, which is unsound from P3.
    `fill_2 = Air` in the `[Coalmine]` example is not alpha 0, so
    the mask reads it as solid. One slot could carry fill 2 and its
    neighbor could carry Rock at the same column, pass the lint,
    and still stop a cave dead at the seam.
  - Paint classes are biome independent, so the check needs no
    biome. It is strictly stronger than the mask, needs no strip
    width, and still runs at P2, where the provisional mapping
    makes it degenerate to the Air mask.
  - It lives in the game package and runs from both tests and
    forge.
- **Dead-end warning (forge only).** For each template slot, every
  boundary port's open component must reach at least one other
  boundary port. This catches caves that stop at a tile center.
  Revision 4 asked for "the ports it should reach", which needs the
  same connect policy that justified cutting the carver. This
  version needs no policy. Openness is biome dependent, so the
  warning resolves fill slots through the biome currently selected
  in forge. It is a warning in `tools/forge`, not a test, because a
  sealed pocket is often deliberate.
- Golden test: a fixed seed, a committed tileset, a pinned region
  size, and pinned biome key colors give a known hash. Key colors
  are inputs because D4 uses them as `biome_salt`. Regenerate the
  hash only on purpose. This is the only check against silently
  regenerating every player's world.
- A unit test pins one material's parsed color against
  `data/materials.txt`. Its absence hid D9 item 6.
- Performance: a benchmark prints generation time. It does not
  assert, because a loaded machine would fail it for unrelated
  reasons. 1 ms per 512x512 chunk at n=64 is a recorded target.

### D9. One config format, one tokenizer

`materials.txt`, `biomes.txt`, and the tileset sidecar share one
format. P1 extracts the section, key, value, and comment tokenizer
from `material_loader.odin` into one procedure that all three use.

This is also a bug fix. The current loader fails silently in five
places, not one, and a tokenizer alone fixes only the first two:

1. The key switch has no default case, so an unknown key is
   dropped. A typo such as `tilesett = ...` would load a biome with
   no tileset and no message.
2. `material_loader.odin:61` skips malformed lines with
   `if eq < 0 do continue`.
3. The `state` switch has no default, so `state = Liquidd` yields
   `.Solid`.
4. Every numeric and color parse uses `if v, ok := ...; ok do ...`,
   so `density = 1..4` yields 0.0.
5. Unknown flag names in `contact`, `immersion`, and `tags` are
   dropped.

6. **Color literals do not parse at all.**
   `material_loader.odin:94` calls
   `strconv.parse_u64_of_base(value, 16)`. That procedure takes an
   explicit base and does not strip a prefix; stripping is what
   `parse_u64_maybe_prefixed` does. On `0xFF5C4033` it reads the
   leading `0`, then `x`, whose digit value is 33 and therefore
   out of base 16, so it returns `ok = false` and the color keeps
   its zero default. **Every material in the repository currently
   has color 0**, and no test asserts a color, so nothing reports
   it.

**Rule: a parse failure or an unknown enum name is an error, not a
default.** The shared tokenizer reports the file name, line number,
and offending text. Silent config failure produces a wrong world
with no message, which is a correctness problem and outside the
skip-it calculus.

Item 6 is load bearing for the rest of the plan. D2 says every data
file uses `0xAARRGGBB`, so the same parse reads biome key colors,
which are also `biome_salt` in D4, and material wang colors in D5.
The shared tokenizer therefore parses a `0x` prefix explicitly. A
unit test pins one material's parsed color against the file, which
is the test whose absence hid this. P0 verifies the behavior of
`parse_u64_of_base` on a prefixed literal, because P0 is the first
step with a compiler.

Item 6 also means the D9 rule cannot land silently: once a parse
failure is an error, the current `data/materials.txt` produces
twelve load errors until the prefix handling is fixed. Fix both in
the same commit at P1.

The tokenizer strips inline comments before it tests for a section
header. The current detector requires the line to end with `]`, so
`[Coalmine]  # comment` falls through to the key path and is
skipped.

All twelve keys in the current `data/materials.txt` are handled,
but the color values do not parse today. See item 6.

## The authoring workflow, end to end

1. Write a `[Tileset]` sidecar. Start at `colors = 1 1 1 1` and
   `vary = 1`, which is 2 template slots and proves the pipeline.
2. Paint the boundary vocabulary in forge Tileset mode. forge
   composes every template slot.
3. Open Preview. The stitched world appears at once.
4. Paint detail into weak slots. The seam lint and the dead-end
   warning run on every reload and mark problems in place.
5. Raise `colors` one class at a time: `2 1 1 1` is 6 slots per
   variant, `2 2 1 1` is 16, `2 2 2 1` is 48, `2 2 2 2` is 128.
   Multiply by `vary` for the number of painted images. Stop where
   the variety is good enough for the art budget. Prefer the class
   pairs that cost 16 over {0,3} and {1,2}, which cost 20.

## Phases

Each phase ends with passing tests and a demonstration in forge.

- **P0 — Toolchain spike, half a day.** On a machine with Odin,
  because this container has none. Verify: `core:image/png` decodes
  RGBA and indexed PNGs; `vendor:stb/image` writes PNGs;
  `core:math/noise` runs; `vendor:raylib` opens a window, blits a
  texture, and reads file modification times; whether raygui ships
  with the distribution; and how `strconv.parse_u64_of_base`
  handles a `0x` prefix, which D9 item 6 says silently zeroes every
  material color today. Any failure changes D7 before code exists.
- **P1 — World skeleton, forge Preview, shared tokenizer.**
  `Material_ID`, the D9 tokenizer with its error reporting, the
  biome table with `[Map]`, biome map loading, the `uniform`
  generator, and generation into a caller-owned slice. Demo:
  Preview shows biome regions from `biome_map.png` with hot reload.
- **P2 — Herringbone core.** Sidecar parsing with dimension
  validation and range checks, `class` with floored division,
  the corner class tables, the block layout and `slot_rect`, `mix`,
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

Revision 7 (validation and a live bug). Recorded a sixth
silent-failure site in the current loader:
`strconv.parse_u64_of_base` does not strip a `0x` prefix, so every
material color in the repository is 0 today and no test reports it.
The same parse feeds biome key colors and wang colors, so the
shared tokenizer handles the prefix and a test pins a parsed color.
P0 verifies the procedure's behavior. Gave the biome table and the
biome map the validation the sidecar already had: an unmatched map
pixel color, required biome keys, name cross-reference resolution,
and unique names and key colors. Recorded that the biome key color
is a terrain input through `biome_salt`, and added it to the golden
test's pinned inputs. Stated that pixels outside every slot
rectangle are ignored, so an editor background does not become a
load error. Renamed the `slot_rect` parameters to `corner_colors`
and `class_counts`, which were both called `colors`. Justified the
1..8 bound by art cost rather than stb compatibility.

Revision 6 (holes, not errors). Specified the template block
layout: each orientation is a grid whose column and row indices
come from three corner digits each, with the split and radices
given in a table, blocks stacked per variant, and an image-size
formula that the dimension check uses. Corrected `slot_rect` to
take the tileset config, because the radices and geometry come from
it. Redefined the seam lint over paint classes rather than an Air
mask: `fill_2 = Air` is not alpha 0, so the mask read a fill as
solid and would pass a seam that stops a cave. Stated the lint's
read direction and that tile-interior lines are excluded. Made the
dead-end warning resolve fills through the selected biome. Recorded
all five silent-failure sites in the current loader, not one, and
set the rule that a parse failure or unknown enum name is an error.
Added required keys, value ranges, biome key color uniqueness, the
reserved `Map` section, the material table size assert, and a
negative fixture for the seam lint. Added `biome_salt` from the
biome key color, so re-skins differ in shape, and forbade deriving
it from the table index. Specified `mix`'s combining rule and
removed the misleading endianness note. Required floored division
for world-to-lattice and world-to-region conversion, with a seam
test across the origin. Labeled slot counts per variant. Made `n`
read-only in Preview, because the dimension check would reject any
other value. Marked which Preview overlays arrive at P2.

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
