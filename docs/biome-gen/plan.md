# Plan: Biome Generation in Odin

Status: revision 4. Revision 3 overreached; this revision corrects
it. See "Revision notes" at the end.

This plan follows the research in `noita-research.md`.

## What revision 3 got wrong

Revision 3 claimed a ladder audit, then net-added scope: it cut five
small items and added a three-mode paint program, a composition
engine, and two tests. It also invented an edge-composition
mechanism, claimed three guarantees for it, and deleted safety
checks that depended on those guarantees. Verification against the
stb source showed the central premise was false.

Corrected here:

- Corner mode does **not** require a tile edge's pixels to depend
  only on its endpoint corner colors. stb matches tiles on the six
  corner colors alone and blits the rect unchanged. Edge continuity
  is an artist discipline, not a property of the scheme.
- Composition therefore guarantees nothing structurally. It is a
  **scaffold**: it writes a correct starting template. Hand edits
  stay legal, so the checks that catch a broken edge must stay.
- Composition does not remove the `c^6` art cost. It removes it
  from **boundaries** only. Interiors still have one connectivity
  case per corner-color combination.
- Composition is **more** repetitive than hand painting, not less.

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
| Chunk pool **and the chunk store** | Generation is pure and per chunk. A map of chunks is a cache for a pure function with no consumer, and it leaks on every reseed. | With streaming. Until then, generate into a caller-owned slice. |
| Per-(biome, tileset) tile compilation | Premature. Revision 2 measured nothing and called the branch cheap; revision 3 reversed that and also measured nothing. | If the P3 benchmark says the branch costs more than the memory. |
| Procedural interior carver | The connect policy is a level-design decision with no local answer, and centroid routing puts a visible junction in every tile. The artist paints interiors. | Only if interior painting proves to be the bottleneck. |
| Avalanche test for `mix` | We vendor splitmix64's finalizer with pinned constants. The test would assert a published result we did not derive. | Never. Determinism, seam, and golden tests already fail loudly on a broken mixer. |

Kept, with the rung that justifies them:

- `core:image/png` decode (rung 2), `vendor:stb/image` encode
  (rung 4), `vendor:raylib` (rung 4), `core:math/noise` (rung 2),
  raygui if bundled (rung 4, verify in P0).
- `mix`, our own hash (rung 6). `core:math/rand` is unusable here:
  its algorithm may change between compiler releases, which would
  regenerate every world. This is a correctness boundary.
- One shared config tokenizer (rung 5). See D9.
- One tool binary with modes, not several binaries.

Restored after revision 3 cut them wrongly:

- **Template dimension validation.** This is memory safety, not
  gold plating. A sidecar and a PNG are separate files, edited
  separately, with hot reload. If they disagree, slot slicing reads
  out of bounds. Hard load error, always.
- **Slot coverage and the edge continuity lint.** Composition
  arrives in P4, but P2 and P3 run on hand-made templates, and hand
  editing stays legal forever. Both checks run on real art.

## Goals

1. Generate an unbounded 2D pixel world from a seed.
2. A small biome-map image controls the world layout.
3. Biomes generate from authored herringbone wang tilesets.
4. Colors in tiles encode materials and biome fills.
5. Any chunk generates alone, in any order, deterministically.
6. Authoring is fast, and mistakes are caught at load.

Non-goals: background wall layer (deferred by decision; migration
is a parallel `background` array plus a companion `_bg.png` per
tileset); spawn points and entities until P6; biome blending, so
borders are hard cuts; chunk persistence and streaming; depth-based
variation; world edges; parallel worlds.

## Design decisions

### D1. World grid and chunks

- The world is an unbounded grid of cells. A cell holds a material
  ID (`u16`). 256 materials fit in `u8`, but the saved memory buys
  nothing we need.
- `Material_ID :: distinct u16`, indexing the material table. It
  does not exist in `material.odin` yet; P1 adds it.
- Generation writes into a caller-owned `[]Material_ID` with an
  explicit width and height. There is no chunk struct and no chunk
  store until streaming exists. The game's chunk size stays a
  compile-time constant, `CHUNK_SIZE :: 512`.
- Future simulation needs per-cell flags, shade, and sparse
  velocity. Those become parallel arrays, not a fat per-cell
  struct. Most cells are static, so a fat cell would drag dead
  bytes through cache.

**On the chunk-size control.** The owner asked for a chunk-size UI
control. It is kept in D7, with one correction: **chunk size does
not change the terrain.** The lattice is anchored at world cell
(0, 0), corner colors hash lattice position, and tile choice hashes
the cell ID. Chunk size only changes how the same world is cut into
pieces. The control is still useful, because it shows seam behavior
and per-chunk cost, but it is not a terrain knob. Terrain structure
comes from `n`.

### D2. Biome map and biome table

- `data/biome_map.png`, decoded with `core:image/png`. One map
  pixel is one chunk.
- `data/biomes.txt` uses the shared format and tokenizer (D9):

```
[Map]
image        = data/biome_map.png
origin_pixel = 35 12        # this pixel is chunk (0, 0)
biome_off_map = Deep_Rock   # default outside the image
biome_above   = Sky         # optional; wins on a diagonal

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
- Finer biome shapes later need only a `cells_per_pixel` key.

### D3. The herringbone lattice, specified

Revision 3 left the core geometry unstated. It is settled now,
derived from the stb source. These are facts, not choices.

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

**Corner class.** For a lattice point at n-grid position `(i, j)`,
`class = (i - j + 1) & 3`. Use floored modulo for negative
coordinates.

**Edge slots.** A horizontal segment runs class `t` to `t+1`. A
vertical segment runs class `t` to `t-1`. Only 6 of the 8 possible
class pairs are ever tile boundaries; the other 2 are tile
interiors:

| Direction | Boundary class pairs | Never a boundary |
| --- | --- | --- |
| Horizontal | (0,1), (1,2), (2,3) | (3,0) |
| Vertical | (1,0), (0,3), (3,2) | (2,1) |

**Edges belong to the lattice, not to a tile.** A horizontal tile's
bottom-left segment is the top edge of a vertical tile. Any
boundary art must therefore be keyed on the lattice edge and shared
across tile orientations. Keying it per tile orientation guarantees
mismatched seams on the most common seam type in the tiling.

**Lattice points are T-junctions.** Every lattice point joins
exactly 3 tiles and has exactly 3 incident boundary edges. The
missing arm depends on the class:

| Class | Arms | No arm |
| --- | --- | --- |
| 0 | right h(0,1), up v(1,0), down v(0,3) | left |
| 1 | left h(0,1), right h(1,2), down v(1,0) | up |
| 2 | left h(1,2), right h(2,3), up v(3,2) | down |
| 3 | left h(2,3), up v(0,3), down v(3,2) | right |

Each edge slot appears exactly twice, once per endpoint.

**Slot count.** For per-class color counts `nc[0..3]`:
horizontal slots `= nc[1]*nc[2]*nc[3] * nc[0]*nc[1]*nc[2]`,
vertical slots `= nc[2]*nc[3]*nc[0] * nc[1]*nc[2]*nc[3]`.
At uniform `c` that is `c^6` per orientation.

**Per-class counts are the art-cost dial.** This is why they stay,
against the advice to collapse them to one number. They give a
smooth ramp instead of a cliff from 2 slots to 128:

| `colors` | Horizontal slots | Total |
| --- | --- | --- |
| 1 1 1 1 | 1 | 2 |
| 2 1 1 1 | 2 | 4 |
| 2 2 1 1 | 4 | 12 |
| 2 2 2 2 | 64 | 128 |

**Our own slot layout.** We do not keep stb compatibility. The
justification was that stb's geometry is "proven", but we write the
slicer ourselves either way, and no stb-authored or Noita-authored
asset could load here. Instead: a horizontal block then a vertical
block, slot index is the six corner colors as mixed-radix digits in
the order `a,b,c,d,e,f`, row major. One procedure,
`slot_rect(colors, orientation) -> Rect`, lives in the game package
and is called by both the engine and the tool. A unit test pins
known indices.

**Tileset sidecar:**

```
# data/tiles/coalmine.txt
[Tileset]
n      = 64
colors = 2 2 1 1   # per corner class
vary   = 2         # interior alternatives per slot
```

- The loader hard-errors if the PNG dimensions disagree with `n`
  and `colors`. It reports both numbers.
- `n` must satisfy `n <= chunk_size / 2`. Alignment
  (`chunk_size %% n == 0`) is a **preference**, not a requirement:
  it reduces partial tiles. Correctness comes from clipping, so a
  tile meeting 4 chunks is handled by the same code path.

### D4. Determinism without neighbor chunks (the core mechanism)

Verified sound across three review rounds. stb generates a whole
map at once: it pre-assigns random corner colors, then picks a
matching tile per cell. We keep that structure and replace both
random streams with position hashes, so any chunk computes any
lattice value locally and neighbors agree by construction.

- **Corner colors.** `color(p) = mix(seed, p.x, p.y, SALT_CORNER)
  %% nc[class(p)]`, with `p` in n-units and floored modulo.
- **Tile choice.** The six corner colors select the slot through
  `slot_rect`. Then
  `tile = mix(seed, c.x, c.y, SALT_TILE) %% vary`. The cell ID is
  the tile's origin corner in n-units. Orientation is a pure
  function of position, so it is not a hash input.
- **`mix`** is splitmix64's finalizer, constants pinned in our
  source. Input encoding is documented and tested: `seed` as
  little-endian `u64`, then `x` and `y` sign-extended from `i32` to
  `u64`, then the salt.
- **One enumeration procedure.** `tiles_overlapping(rect, n)` is an
  **iterator** over a caller-held state struct, not a returned
  slice, so chunk generation allocates nothing. It yields origin,
  orientation, and overlap sub-rectangle. Engine and tool both use
  it, so the lattice has one definition and one test.
- **No PRNG streams in worldgen.** Draw order differs per chunk, so
  a stream would break seams. Every random-looking decision is a
  position hash with its own salt.
- **Biome borders.** The lattice, tileset, and hashes are scoped
  per biome. A chunk generates from its own biome only and never
  inspects a neighbor, because it writes only inside its own
  rectangle. Clipping at a biome border is the same code path as
  clipping at the chunk rectangle, so no cell is left undefined.
- **Dropped: stb's repetition-reduction pass.** It mutates the
  color grid in sequence, which cannot run per chunk. **There is
  currently no repetition mitigation.** The first lever is `vary`.
  The recorded upgrade is a hash-local flip: change a corner when
  its fixed-size neighborhood of base hash colors matches a repeat
  pattern, which stays deterministic and order free.

### D5. Paint semantics

Each material gets a `wang_color`: the color that represents it in
authored PNGs. It defaults to the display `color` but is a separate
value in the cold parallel table, so display colors stay tunable
without repainting art, and two materials may share a display color
but never a paint key. `Material_Table` gains `wang_colors: []u32`.
The hot 32-byte `Material` struct does not change.

Priority order per template pixel:

1. Alpha 0 gives Air.
2. A gray fill shade gives a biome fill slot 0..7. These are
   exactly the 8 values `0xFF101010, 0xFF202020, ... 0xFF808080`,
   step `0x10` per channel. Other grays stay available as wang
   colors.
3. A material `wang_color` gives that material.
4. Anything else is a load error reporting the pixel position.

Color keys must have alpha `0xFF`. Air is the exception, covered by
rule 1.

Validation at load: gray fill shades and material wang colors must
be disjoint, and a collision names both owners. Every biome must
define every fill slot its tileset uses.

**Compilation and the blit.** Each slot compiles once into a flat
`[]u16`. Fill slots compile to reserved IDs `0xFFF8..0xFFFF` and
resolve during the blit through the biome's 8-entry table. That is
one predictable branch per cell. Revision 3 replaced this with
per-(biome, tileset) resolved copies to get a pure memcpy; that is
reverted as premature, because it multiplies memory by the number
of biomes sharing a tileset, adds a bind cache and an invalidation
path on hot reload, and was never measured. P3 measures it. Target:
a chunk generates in under 1 ms at n=64.

### D6. Noise and uniform generators

- `generator = uniform` fills one material. It is the P1 skeleton.
- `generator = noise` uses OpenSimplex2 from `core:math/noise` with
  a short fBm loop, because core has no fBm. A threshold picks cave
  or solid, and a second channel places ore veins. Parameters live
  in `biomes.txt` (`frequency`, `octaves`, `threshold`, `solid`,
  `open`, `vein`, `vein_freq`, `vein_cut`).
- Noise input is absolute world position; the seed offsets the
  domain.

**Open question, reopened.** Revision 3 closed cross-platform
determinism by saying the game ships one artifact per platform with
`when ODIN_OS` checks. That does not address the risk. Float
divergence comes from FMA contraction, x87 versus SSE, libm
differences, and optimization level; a per-OS build addresses none
of them, and per-platform artifacts are exactly the seed-sharing
failure case rather than a defense. Noita players do share seeds.
Exposure is limited to P5 noise biomes, because wang biomes are
integer math. The escape hatch is an integer value-noise built on
`mix`, which is a handful of lines. **Decide before P5 ships
widely.**

### D7. forge: one tool, modes added when earned

`tools/forge` is a single `vendor:raylib` binary sharing one
window, one palette renderer, one loader, and one generator. It is
a thin shell over the game package, so it exercises the real code
path. Widgets come from raygui if bundled, verified in P0.

Common to all modes: hot reload by polling file modification times,
because raylib has no file watcher; load errors drawn in the window
at the offending pixels, not only in the console.

Revision 3 shipped three modes at once and deleted revision 2's
gate on in-tool painting. The gate is restored: **Preview is
built first, and a painting mode is built only when the phase that
needs it arrives.**

**Preview mode (P1).** Generates a region through the real pipeline
and draws it with material display colors. Overlays on toggle:
chunk borders, the lattice with corner colors and classes, biome
map regions. Click a pixel for material name, tile ID, and source
slot, so a bad seam points back to the slot that made it. Steppers
for `n` and chunk size, with the D1 caveat that chunk size changes
only the cut, not the terrain. Reseed key.

**Tileset mode (P4).** The painting mode, built when authoring
starts. Its job is the part Aseprite cannot do, which is knowing
the constraint rules.

- Paint with squares that map to single pixels, at a chosen zoom.
- The palette is constrained by construction: material wang colors
  by name, and the 8 gray fills labeled with the material each
  currently resolves to. Off-palette colors and anti-aliasing
  become impossible, without relying on editor settings.
- Info panel: slot index, its six corner colors, slot counts, and
  memory cost of the current `n` and `colors`.
- **Composition, as a scaffold.** The artist paints a boundary
  vocabulary, and forge stamps it into every slot as a starting
  point:
  - **Edge strips**, keyed on `(edge_slot, color_low, color_high)`
    where `edge_slot` is one of the 6 in D3 and the endpoints are
    named by class, never by a global color index. At uniform `c`
    that is `6c^2` strips: **24 at c=2**, not the 8 that revision 3
    claimed. Strips are shared across tile orientations.
  - **Corner hubs**, one per class and color, shaped as the
    3-armed T-junctions in D3's arm table.
  - Strip width `w` is a sidecar field. The compositor and the
    lint both need it.
  - Composition then writes a normal template PNG. **The engine
    format does not change and gains no new failure mode.**
- **What composition does and does not buy.** It makes boundaries
  cheap and consistent, and it writes every slot so a fresh
  template is never under-covered. It does **not** make anything
  structural, because hand edits stay legal. It does **not** remove
  the `c^6` cost from interiors: each slot's interior must connect
  its open boundary ports, and the number of distinct connectivity
  cases is again one per color combination. Interiors are painted,
  not carved.
- **Composition is more repetitive than hand painting.** At n=64
  and c=2 a 512-cell chunk holds 32 tiles, 96 lattice edges, and 64
  lattice points, drawn from 24 strips and 8 hubs. Each hub appears
  about 8 times per chunk, pixel identical, everywhere in the
  world. `vary` cannot fix this: stb variants share corner colors,
  so variants may differ **only** in interiors, never on edges. The
  strip and hub vocabulary is therefore an irreducible floor.
- **Consequence: compose, then detail.** Composition is a
  scaffold, not a product. The artist hand-details high-traffic
  slots afterward, and the continuity lint catches detailing that
  breaks a seam.
- **Re-composition must not destroy hand work.** Data loss is
  outside the skip-it calculus. Rule: composition writes the
  template only when the template is older than its parts, and
  refuses otherwise with a message naming both times. An explicit
  `--force` overwrites.

**World Map mode (after P4).** The owner asked for this, and it is
worth building, but not first: it is the most code of any mode for
the least risk, and the first biome map is a handful of pixels. It
draws the map as large squares, one per chunk, with a palette of
biomes by name, and an info panel showing chunk coordinate, biome,
generator, and covered world rectangle. Until then the cheap answer
covers it: forge exports a `.gpl` palette that Aseprite and GIMP
both import, so the map can be painted there with named colors.

### D8. Testing

All tests run with `odin test src`.

- Unit: config tokenizer, including unknown keys and malformed
  lines; RGBA to ARGB conversion; `class(p)` including negative
  coordinates; the 6 edge slots and the arm table; `slot_rect` on
  pinned indices; `tiles_overlapping` counts, orientations, and
  sub-rectangles; paint semantics and every error case; color
  disjointness; fill coverage; template dimension mismatch.
- Determinism: one seed gives `mem.compare`-identical output. A
  different generation order gives an identical world.
- Seam tests: two adjacent regions generated independently share
  identical border cells. A biome-border case checks that clipping
  is stable.
- **Edge agreement lint.** For each of the 6 edge slots, every slot
  in the template carrying it must agree on those `w` pixels,
  **including across tile orientations**, which is where a
  per-orientation keying bug would surface. This is a procedure in
  the game package, called from forge on real art and from tests on
  committed tilesets. Revision 3's version tested only composed
  output, where it was true by construction and therefore powerless.
- **Interior connectivity lint.** For each slot, compute connected
  components of Air and assert every open boundary port reaches the
  ports it should, with no unintended sealed pocket. This catches
  caves that dead-end at a tile center, which no other check sees.
  It runs in forge on real art.
- Golden test: a fixed seed and a committed tileset give a known
  hash. Regenerate only on purpose. It is the only guard against
  silently regenerating every player's world.
- Performance: a benchmark **prints** chunk generation time. It
  does not assert, because a loaded machine would fail it for
  reasons unrelated to the code. 1 ms at n=64 is a recorded target.

### D9. One config format, one tokenizer

`materials.txt`, `biomes.txt`, and the tileset sidecar are the same
format. P1 extracts the section, key, value, and comment tokenizer
from `material_loader.odin` into one procedure that all three use.

This is also a bug fix. The current loader's key switch has no
default case, and `if eq < 0 do continue` skips malformed lines. A
typo such as `tilesett = ...` would load a biome with no tileset
and no error, which is a wrong world with no message. The shared
tokenizer reports unknown keys and malformed lines with the file
name and line number. Silent config failure is a correctness
problem, not a nicety.

## The authoring workflow, end to end

1. Write a `[Tileset]` sidecar. Start at `colors = 1 1 1 1`, which
   is 2 slots and proves the pipeline.
2. Paint the boundary vocabulary in forge Tileset mode. forge
   composes all slots.
3. Open Preview. The stitched world appears immediately.
4. Detail slots that look weak. The edge and connectivity lints run
   on every reload and mark problems in place.
5. Ramp `colors` one class at a time: `2 1 1 1` is 4 slots,
   `2 2 1 1` is 12, `2 2 2 2` is 128. Stop where the variety is
   good enough for the art budget.

## Phases

Each phase ends with passing tests and a demo in forge.

- **P0 — Toolchain spike, half a day.** On a dev machine, because
  this container has no Odin. Verify: `core:image/png` decodes RGBA
  and indexed PNGs; `vendor:stb/image` writes PNGs;
  `core:math/noise` runs; `vendor:raylib` opens a window, blits a
  texture, and reads file modification times; whether raygui ships
  with the distribution. Any failure changes D7 before code exists.
- **P1 — World skeleton, forge Preview, shared tokenizer.**
  `Material_ID`, the D9 tokenizer with its error reporting, biome
  table with `[Map]`, biome map loading, `uniform` generator,
  generation into a caller-owned slice. Demo: Preview shows biome
  regions from `biome_map.png` with hot reload.
- **P2 — Herringbone core.** Sidecar parsing with dimension
  validation, `class`, `slot_rect`, `mix`, `tiles_overlapping`,
  template slicing, per-region generation with cross-border
  blitting, slot coverage, the edge agreement lint. Provisional
  paint mapping: alpha 0 gives Air, any other pixel gives one test
  material. Determinism and seam tests. Demo: `1 1 1 1` then
  `2 2 1 1` debug tilesets stitching seamlessly.
- **P3 — Paint semantics.** `wang_color` in the cold table, gray
  fills, disjointness, fill coverage, load errors with positions,
  golden test, and the blit benchmark that decides D5's open
  compilation question. Demo: one tileset re-skinned by two biomes.
- **P4 — forge Tileset mode and the first real biome.** The
  constrained palette, the info panel, edge strips, corner hubs,
  the compositor with its overwrite rule, and the interior
  connectivity lint. Then author a coalmine-alike, ramping `colors`
  as the art allows. Authoring is the riskiest unvalidated step, so
  the phase ends when a real biome looks right in Preview.
- **P5 — Noise biomes.** The fBm wrapper and tests, ore veins, sky
  and deep-rock biomes. Decide the D6 cross-platform question
  first.
- **P6 — Pixel scenes and spawn markers.** PNG stamps with D5
  semantics, anchor markers, and a global fixed-position list. This
  is where the marker mechanism cut from P3 returns.
- **Later — World Map mode**, then background layer, streaming,
  the chunk store, and the chunk pool.

## Revision notes

Revision 4 (correcting revision 3): recorded that revision 3
overreached. Verified the herringbone geometry against the stb
source and specified it: the 6 corner points per orientation, the
class formula, the 6 edge slots, the T-junction arm table, the slot
count formula, and our own slot layout. Corrected the composition
model: the "edge pixels depend only on endpoint colors" premise is
false as a property of corner mode, the strip count is `6c^2` and
keyed on lattice edges shared across orientations rather than 8
keyed per orientation, composition is a scaffold rather than a
guarantee, it does not remove the `c^6` interior cost, and it
increases repetition. Restored template dimension validation, slot
coverage, and the edge continuity lint, and added an interior
connectivity lint. Cut the interior carver, the chunk store, the
per-pair compilation, and the avalanche test. Kept per-class color
counts as the art-cost ramp. Added D9, one tokenizer for all config
files, fixing a silent-failure bug in the existing loader. Made
`tiles_overlapping` an iterator. Made the benchmark print instead
of assert. Reopened the cross-platform determinism question with
the correct technical reason. Recorded that chunk size does not
change terrain. Restored the gate on in-tool painting and moved
World Map mode after P4.

Revision 3: ladder audit; cut spawns, pool, and other items; added
forge and composition. Substantially corrected above.

Revision 2: provisional paint mapping for P2; corrected per-chunk
tile counts; pinned the tile-choice hash input; made gray fills
exactly 8 values; required alpha `0xFF`; added fill coverage.

Revision 1 (three adversarial reviews): fixed a self-contradiction
where tile choice used a chunk-seeded PRNG, which broke the seam
guarantee; added per-biome lattice scoping; specified per-class
moduli and floored modulo; ran the `c^6` combinatorics; closed the
PNG encode hole with `vendor:stb/image`; split `wang_color` from
display `color`.
