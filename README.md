# The Game

A Noita-like game created in Odin from scratch.

## Vision

Classical virtue and discovered narrative.

Physics, chemistry, alchemy, adventure, beauty, sacrifice, tinkering, exploration, defeat, victory.

## Priorities

- Simplicity
- Ease of change
- End-to-end performance
- Testability

## Rules

- Code uses the ponytail complexity ladder.
- Prose uses Simplified Technical English.
- Prefer fat structs and data-oriented design focused on CPU and cache behavior.

See `AGENTS.md` for the short form of the project vision.

## Build and run

The game uses Odin and the raylib package that ships with it. Run
every command from the repository root, because the data paths are
relative to it.

```sh
odin run src        # play
odin test src       # run the tests
make                # builds the binaries into bin/
```

There is no toolchain in the box. `sudo tools/build-toolchain.sh`
builds the Odin compiler and the raylib library it links, which takes
about five minutes; `docs/toolchain.md` says what it does.

`bin/shot` draws a rectangle of the world into a PNG with no window
and no display, which is how to look at what an edit did:

```sh
make shot
./bin/shot biome=Coalmine grid=1 out=shots/coalmine.png
```

Built and tested against the Odin dev-2026-08 release. It uses the
current `core:os`, where a file operation returns an `Error` rather
than a `bool`.

## Biome generation

One complete loop: paint a biome map, paint the tiles a biome is made
of, watch the world change, then save.

- `data/materials.txt` holds the materials.
- `data/biomes.txt` holds the biomes. Each biome has a key color, one
  fill material, and either a flat fill or a set of tiles.
- `data/biome_map.png` is the world layout. One pixel is one region
  of 512x512 world cells. The game writes a starter map if the file
  is absent.
- `data/tiles/` holds the tile sets, one PNG per tile.
- `data/sprites/wizard.png` holds the player, one row per animation.

### Wang tiles

A biome with `generator = wang` owns a set of 256x256 tiles. The world
is cut into a lattice of tile squares, and each square draws one tile
of the set of the biome that owns it. One cell of a tile is one world
cell, so what the author paints is what the wizard walks through. Borders between biomes stay hard
cuts; inside one biome the lattice runs on unbroken, across region
borders as well.

Which tile lands where is a Wang tiling. Every tile carries a color on
each of its four sides. The lattice colors each of its edges from a
hash of the position of that edge, and a square takes the tile whose
four sides match the four edges around it. Two squares beside each
other read one edge, so the tiles that land on them always agree about
it, and no rectangle of world has to be generated before another one:
the world is still unbounded and still generates in any order.

Two edge colors make a complete set 16 tiles. `variants` draws several
pictures of one set of edges, and the lattice picks between them with
a second hash, so the same four edges do not always give the same
tile. The Coalmine set ships with two.

Matching colors is only half of a seam. The cells within 4 of a
side belong to the edge color rather than to the tile: every tile that
carries color 1 on its west side holds the same 4 columns there. The
seeder crossfades a tile's own noise into those columns, so the join
is smooth well beyond them and the lattice leaves no line. A
corner cell sits in two bands at once, so the whole set shares it,
which is why the bands stay narrow. The tile editor keeps all of that
true as you paint, and the save gate refuses a set where it is not.

A tile file is named after what it carries:

```
data/tiles/coalmine_0110_1.png
                    NESW variant
```

The sets are authored data, and the tile editor is how to change one.
A whole set is 32 pictures, so `tools/seed_tiles.py` draws one: caves
cut from noise, about half of every tile open. It reads the
material and biome tables, so a new biome only needs `generator = wang`
and a `tiles` prefix to be seeded, and `--check` holds the files on
disk to the seam rule.

### Controls

The window opens on the wizard, standing at the top of the world beside
a hole into the caves.

| Key | Action |
| --- | --- |
| `A` `D` or left and right | Walk |
| `SHIFT` | Run |
| `SPACE`, `W` or `UP` | Jump; hold it in the air to fly |
| Mouse wheel, `-`, `=` | Zoom out and in |
| `TAB` | Open and close the world editor |

Tap the jump key and he jumps. Hold it and the jetpack lights, which
empties the tank in two seconds and fills it again in under one while
he stands. `docs/player.md` says how he is built and what the phase
leaves out.

The world editor takes the camera back, so the same keys pan it again:

| Key | Action |
| --- | --- |
| `WASD` or arrows | Pan the camera |
| Left mouse | Paint the selected biome |
| Right mouse | Erase a map pixel |
| `1` to `9` | Select a biome |
| `M` or middle mouse | Look at the region under the cursor |
| `T` | Open the tile set of the selected biome |
| `S` | Save the map image |

The world regenerates as you paint. Save is blocked while the painted
map falls into more than one connected region, and the editor outlines
the stranded pixels in red.

In the tile editor:

| Key | Action |
| --- | --- |
| Left mouse | Paint the selected material |
| Right mouse | Erase to air |
| `[` and `]` | Walk the set |
| `V` | Next variant of this tile |
| `1` to `9` | Select a material |
| `M` | Look at a region of this biome |
| `N` | Make the seams agree again |
| `S` | Save every tile of the set |
| `T` or `TAB` | Close |

The tile in hand is drawn with the neighbour strips that would sit
beyond each side, so a seam is always painted as a joined picture. The
four edge colors are drawn on the sides they belong to, and the whole
set is on screen beside it.

## Layout

```
src/       the game, package game, with the tests beside the code
cmd/mcp/   the MCP server binary
cmd/shot/  the world as a PNG
data/      the materials, the biomes, the biome map, the tiles, the sprites
docs/      the design notes and the toolchain
tools/     the toolchain build, the tile seeder, and the wizard seeder
```

The game is made of three parts. The biome map says which biome owns
which region. A tile set says what a biome is made of. The
sandbox says what a rectangle of that world does next: sand falls, oil
burns, smoke climbs.

The player walks on the first of those and not yet on the third, so the
world does not move under him. `docs/player.md` says why, and names the
step that joins them.

| File | What it holds |
| --- | --- |
| `src/worldgen.odin` | The generator: what a world cell is made of |
| `src/biome*.odin` | The biome table and the biome map |
| `src/tile*.odin` | The tiles and their PNG files |
| `src/wang.odin` | The tile lattice, the edge colors, the seam rule |
| `src/editor.odin` | The world editor, model and window |
| `src/tile_editor.odin` | The tile editor, model and window |
| `src/player.odin` | The wizard: his body, his step, and where he starts |
| `src/sprite.odin` | The sprite sheet, and which frame of it to draw |
| `src/sandbox.odin` | The cell grid and the falling sand step |
| `src/input_queue.odin` | The input queue |
| `src/sim.odin` | The whole game state, with no window in it |
| `src/mcp*.odin` | The MCP server |
| `src/main.odin` | The game window |
| `src/shot.odin` | The world as a PNG, with no window |

## Play and author through MCP

The game also runs as an MCP server, so a model can author the world
and play it: paint the biome map, paint a tile, open a sandbox on the
region those edits describe, and run the sand over it.

```sh
make mcp
claude mcp add the-game -- ./bin/game-mcp
```

Every editor tool calls the same procedure the mouse calls, so a model
and a hand cannot paint different worlds. Saving the biome map meets
the same connectivity gate either way.

Commands reach the sandbox through an input queue taken from old
lockstep network code. A command carries an execution tick, not a time,
so the speed of the client does not change the world that comes out.
The same seed, region, and commands always give the same checksum.

See `docs/mcp.md` for the tools and the limits.
