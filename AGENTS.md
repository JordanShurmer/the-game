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
./bin/shot player=1 out=shots/wizard.png                # the wizard where he starts
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

## Draw a biome

The tile PNGs in `data/tiles/` are authored data. Small changes belong
in the tile editor (press T in the world editor) or in the MCP tile
tools, which keep the Wang seam rule for you. A whole set is 32
pictures, which is not hand work, so there is a tool for that:

```sh
tools/seed_tiles.py --list                 # which biomes draw a set
tools/seed_tiles.py Coalmine --force       # OVERWRITES its 32 tiles
tools/seed_tiles.py Coalmine --force --seed 12345   # another drawing
tools/seed_tiles.py --check                # hold the files to the seam rule
```

It reads `data/materials.txt` and `data/biomes.txt`, so a biome only
needs `generator = wang` and a `tiles` prefix there to be seeded. The
`STYLES` table in the script says which materials a biome is made of,
and the constants above it say how open the caves are. With no
`--seed` it draws the tiles that are in the repository, exactly, so a
change to the tool shows up as a change to the data.

Read the header of that script before changing terrain generation. It
holds the two rules that are easy to break and only visible in a shot
of the whole world.

## Where things are

| Path | What it holds |
| --- | --- |
| `src/` | the game, package `game`, tests beside the code |
| `cmd/mcp/` | the MCP server, for authoring and playing through a model |
| `cmd/shot/` | the world as a PNG |
| `data/` | materials, biomes, the biome map, the tile sets, the sprites |
| `docs/` | the design notes and the toolchain |
| `tools/` | the toolchain build, the tile seeder, and the wizard seeder |

## The player

`docs/player.md` is the design note: how the wizard is built, the
numbers he moves by, and what this phase leaves out. Read it before
changing `src/player.odin` or `src/sprite.odin`.

Two rules there are easy to break and hard to see:

- **His body is 13 cells tall because the world allows no more.** Two
  tiles that meet share a band, and the clear channel through it is 16
  painted cells, which the world draws `TILE_SCALE` times wider: 32
  cells today. A taller body fits every cave and leaves none of them.
  `test_the_player_fits_the_world` measures the real tiles, converts to
  world cells, and fails when a reseed or a smaller `TILE_SCALE` closes
  the channel.
- **The drawing and the collision box are two numbers that must agree.**
  `tools/seed_wizard.py` holds the body box, `src/sprite.odin` asserts
  it matches `src/player.odin`, and `--check` holds the sheet to it.

```sh
tools/seed_wizard.py           # redraw data/sprites/wizard.png
tools/seed_wizard.py --check   # hold the file to the rules
```

A pixel editor works on a tile too, but then the save gate may report
a seam that no longer agrees, and `N` in the editor mends it.
