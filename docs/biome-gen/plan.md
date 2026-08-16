# Plan: Biome Generation

This plan follows the research in `noita-research.md`.

Work is ordered as end-to-end experiences. Each phase leaves a
complete loop you can open, see, and change. Later phases deepen
the same path.

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

Non-goals for early phases: background wall layer; spawn points and
entities until needed; biome blending (borders are hard cuts);
chunk persistence and streaming; depth-based variation.

## Phase 1 — In-game world editor, solid biome fills

**Experience**

You are in the game. You open the world editor.

- The editor shows a grid of biome placements.
- Each biome type has a distinct color.
- You paint biomes onto the map.
- The world map is a PNG: each pixel is one placed biome.
- As you paint, the live world regenerates in real time. You do not
  need to press Save to see the change.
- Save writes the PNG. Save is blocked while any biome region is
  disconnected (a placed biome must form one connected component,
  or the rule the design settles on for connectivity).
- World generation reads that PNG. Each biome-map pixel becomes a
  region filled entirely with that biome’s `fill_material`.

That is the whole vertical path for Phase 1: paint → live regen →
save (when connected) → solid fill world.

**What is built**

- Biome table (`biomes.txt` or equivalent): name, key color, and one
  fill material per biome.
- Biome map PNG load and save.
- Uniform generator: for a requested world rectangle, fill every
  cell from the biome that owns its region, using that biome’s fill
  material only.
- In-game world editor overlay:
  - Palette of biome types by color and name.
  - Paint / erase on the map grid.
  - Live call into the same `generate` path the game uses.
  - Connectivity check; Save disabled (or blocked with a clear
    message) while any biome is disconnected.
  - Optional: highlight disconnected components.
- Hard load errors for unmatched map colors and missing required
  biome data.

**Rules for Phase 1**

- One biome-map pixel is one region (default size pinned, e.g. 512
  cells; overridable later).
- Generation writes into a caller-owned material buffer. No chunk
  store yet.
- World-to-region conversion uses floored division so negative
  coordinates work.
- The editor and the game share one generate path. Live regen and
  load-from-disk use the same code.
- Connectivity is checked on the biome map (pixel graph), not on
  world cells.

**Tests**

- Determinism: same map + seed → identical buffer.
- Unmatched map colors and missing biome keys are hard errors.
- Connectivity: connected maps may save; a disconnected placement
  fails the gate.
- Live regen path matches generate-from-disk path for the same map.

**Demo**

Open the game, open the editor, paint two biomes, watch solid
regions appear in the world as you paint, connect them, save, quit,
reload, and see the same layout.

## Phase 2 — Biome tile editor (basic)

**Experience**

Open a simple tile editor for one biome. Paint a solid or simple
pattern. The world editor still works. Regions of that biome now
show the tile pattern instead of a flat fill.

No herringbone lattice yet. The path is: paint a tile → it appears
in the live world for that biome.

## Phase 3 — Herringbone tiles

**Experience**

The same world and editor now show seamless herringbone terrain for
wang biomes. Change seed; arrangement changes; seams stay clean.

Lattice geometry, position-hash determinism, seam lint, and the
shared tileset format land here. Start art at the cheapest counts
(`colors = 1 1 1 1`).

## Phase 4 — Full paint semantics

**Experience**

One tileset re-skinned by two biomes with different fill mappings.
Gray fill slots and material wang colors. Golden test locks a fixed
seed.

## Phase 5 — Advanced tileset tools

**Experience**

Paint boundary vocabulary (edge strips, corner hubs). Compose a
full template. Seam lint and dead-end warnings mark problems.
Composition does not overwrite newer hand work unless forced.

## Phase 6 — First real biome and noise biomes

**Experience**

Author a coherent Coalmine. Add Sky and Deep_Rock (uniform or
noise). The same in-game editor and generate path still work.

## Design rules that every phase obeys

### World grid and regions

- A cell holds a material id.
- One biome-map pixel is one region.
- A chunk is only a cut: how much the caller asks for. No chunk
  store until streaming exists.

### Biome map and table

```
[Map]
image         = data/biome_map.png
origin_pixel  = 0 0
biome_off_map = Deep_Rock
cells_per_pixel = 512

[Coalmine]
color     = 0xFFD57917
generator = uniform          # later: wang | noise
fill_0    = Rock
```

Hard load errors for unmatched map colors, missing required keys,
unresolved names, and duplicate key colors.

### Determinism (from Phase 3)

Every random-looking decision is a position hash. Neighbors agree
by construction. Generation never reads a neighbor region.

### What is cut until needed

- Spawn tables and entity markers.
- Chunk pool / store.
- Wang lattice and tileset composition before Phase 3 / 5.
- Procedural interior carver.

## Later

Background layer, streaming, and deeper authoring tools when the
game needs them.
