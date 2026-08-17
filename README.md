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
make                # builds both binaries into bin/
```

Built and tested against the Odin dev-2026-08 release. It uses the
current `core:os`, where a file operation returns an `Error` rather
than a `bool`.

## Biome generation, phase 1

Phase 1 is one complete loop: paint a biome map, watch the world
change, then save.

- `data/materials.txt` holds the materials.
- `data/biomes.txt` holds the biomes. Each biome has a key color and
  one fill material.
- `data/biome_map.png` is the world layout. One pixel is one region
  of 512x512 world cells. The game writes a starter map if the file
  is absent.

Every biome fills its regions with one material, so borders are hard
cuts. Wang tiles arrive in a later phase.

### Controls

| Key | Action |
| --- | --- |
| `WASD` or arrows | Pan the camera |
| Mouse wheel, `-`, `=` | Zoom out and in |
| `TAB` | Open and close the world editor |
| Left mouse | Paint the selected biome |
| Right mouse | Erase a map pixel |
| `1` to `9` | Select a biome |
| `M` or middle mouse | Look at the region under the cursor |
| `S` | Save the map image |

The world regenerates as you paint. Save is blocked while the painted
map falls into more than one connected region, and the editor outlines
the stranded pixels in red.

## Layout

```
src/       the game, package game, with the tests beside the code
cmd/mcp/   the MCP server binary
data/      the materials, the biomes, the biome map, the tiles
docs/      the design notes
```

The game is made of three parts. The biome map says which biome owns
which region. A tile says what one region of a biome is made of. The
sandbox says what a rectangle of that world does next: sand falls, oil
burns, smoke climbs.

| File | What it holds |
| --- | --- |
| `src/worldgen.odin` | The generator: what a world cell is made of |
| `src/biome*.odin` | The biome table and the biome map |
| `src/tile*.odin` | The tiles and their PNG files |
| `src/editor.odin` | The world editor, model and window |
| `src/tile_editor.odin` | The tile editor, model and window |
| `src/sandbox.odin` | The cell grid and the falling sand step |
| `src/input_queue.odin` | The input queue |
| `src/sim.odin` | The whole game state, with no window in it |
| `src/mcp*.odin` | The MCP server |
| `src/main.odin` | The game window |

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
