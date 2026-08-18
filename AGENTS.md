What we're creating: A Noita like game with classical virtue and discovered narrative. Created in Odin from scratch. Physics, chemistry, alchemy, adventure, beauty, sacrifice, tinkering, exploration, defeat, victory. When writing code use the ponytail complexity ladder. When writing prose use Simplified Technical English. Prioritize simplicity, ease of change, end to end performance, and testability.

## Build

Run every command from the repository root, because the data paths are
relative to it.

```sh
odin check src -vet     # types, and the things vet catches
odin test src           # the whole suite, about a second
make                    # bin/the-game, bin/game-mcp, bin/shot
```

If `odin` is not on the PATH, build it: `sudo tools/build-toolchain.sh`
takes about five minutes and needs the network. See
`docs/toolchain.md` for what it does and why raylib needs building.

## Look at the world

The world is a picture, so read it as one. `bin/shot` draws a
rectangle of the authored world into a PNG through the same generate
path the game window draws through. It needs no display.

```sh
make shot
./bin/shot biome=Coalmine out=shots/look.png            # a region, close up
./bin/shot biome=Coalmine grid=1 out=shots/grid.png     # with the tile lattice
./bin/shot biome=Coalmine step=2 out=shots/wide.png     # pulled back
```

Then open the PNG and look at it. `grid=1` draws the tile lattice and
the region borders, which is how to tell a shape you drew from a seam
the lattice left. Arguments are `key=value`: `out biome x y w h step
scale grid`. Shots are not kept in the repository.

## Iterate on the world

1. Change the tiles or the code.
2. `odin test src`.
3. `./bin/shot ...` and look at the picture.
4. Repeat until it reads right, then commit.

Judge terrain by the picture, not by the code. A tile set is 32 small
images and a biome is a lattice of them, and neither says how a cave
system reads until it is drawn at size. Two things are only ever
visible in a shot: whether the lattice shows through as a grid, and
whether the caves join up across the borders between tiles.

## Where things are

| Path | What it holds |
| --- | --- |
| `src/` | the game, package `game`, tests beside the code |
| `cmd/mcp/` | the MCP server, for authoring and playing through a model |
| `cmd/shot/` | the world as a PNG |
| `data/` | materials, biomes, the biome map, the tile sets |
| `docs/` | the design notes and the toolchain |
| `tools/` | the toolchain build |

The tile PNGs in `data/tiles/` are authored data. Change them in the
tile editor (press T in the world editor) or through the MCP tile
tools, which keep the Wang seam rule for you. A pixel editor works
too, but then the save gate may report a seam that no longer agrees,
and `N` in the editor mends it.
