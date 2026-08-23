What we're creating: A Noita like game with classical virtue and discovered narrative. Created in Odin from scratch. Physics, chemistry, alchemy, adventure, beauty, sacrifice, tinkering, exploration, defeat, victory. Everything in the world is a material, a row in `data/materials.txt`, including things that are not obviously matter, like light and explosions. When writing code use the ponytail complexity ladder. When writing prose use Simplified Technical English. Prioritize simplicity, ease of change, end to end performance, and testability.

## Build

Run every command from the repository root, because the data paths are
relative to it.

```sh
odin check src -vet     # types, and the things vet catches
odin test src           # the whole suite, under ten seconds
make                    # bin/the-game, bin/game-mcp, bin/shot
make bench              # bin/bench, which times a tick
```

If `odin` is not on the PATH, install it:
`sudo tools/install-toolchain.sh` takes about half a minute and needs
the network. See `docs/toolchain.md` for what it does, and why the
Odin repository must not be cloned to get raylib.

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
./bin/shot walk=-600 out=shots/dark.png                 # walked, with the light he left
```

The water shader runs on the GPU, so `bin/shot` cannot draw it and
paints the pond flat. The game takes a shot of its own window instead,
which needs a display:

```sh
make game
./bin/the-game shot=shots/water.png frames=140 walk=-40
# with no display: xvfb-run -a -s "-screen 0 1280x720x24" ./bin/the-game shot=...
```

Its arguments are `shot` (the PNG to write), `frames` (how many frames
to draw first, which is what moves the water) and `walk` (ticks of walk
before the picture, negative for left, toward the pond).

Then open the PNG and look at it. `grid=1` draws the tile lattice and
the region borders, which is how to tell a shape you drew from a seam
the lattice left. Arguments are `key=value`: `out biome x y w h step
scale grid player light walk ticks ignite explode`. Shots are not kept
in the repository.

`player=1` lights the shot, because the wizard carries nearly all the
light there is; `light=0` turns that off and draws the world flat, which is
what terrain is judged by. `walk=N` walks him N ticks first (negative
walks left), which is the way to see the trail of crystals he leaves.

A room lit by nothing but its own reaction has no wizard in it at
all: `light=1` with no `player` follows the middle of the view
instead of the origin, so a shot can judge a light source far from
where he starts. See `docs/alchemy.md`, "Looking at it".

## Look at one material

Every material may bring a shader, `data/shaders/materials/<name>.fs`,
which is what makes a cell of gold read as metal and a cell of rock read
as stone. A shader is judged by a picture, and a four-cell vein in an
unlit cave is not one, so the game has a bench that fills the whole view
with one material in the shapes a shader has to answer for:

```sh
make game
xvfb-run -a -s "-screen 0 1280x720x24" \
    ./bin/the-game look=Gold shot=shots/gold.png frames=25
```

Shader files are read at load, so nothing needs building between one
picture and the next. Read `docs/material_shaders.md` before writing one:
it holds the contract, the helpers, and what makes a material read as
itself.

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
| `cmd/bench/` | what a tick costs, on a real region |
| `data/rooms/` | the painted regions: the galleries, the homelands, the cavemouth |
| `data/shaders/materials/` | one shader a material, and the prelude they share |
| `data/` | materials, biomes, the biome map, the tile sets, the sprites, the shaders |
| `docs/` | the design notes and the toolchain |
| `tools/` | the toolchain install, the tile seeder, the wizard and drudge seeders, and the gallery seeders |

## The homelands

`docs/homelands.md` is the design note: the six surface regions the
wizard starts on, the twelve pictures they are drawn from, the mouth
east of them, and where he is put. Read it before changing
`tools/seed_homelands.py`, `src/homelands.odin`, or the `[Homelands]`
and `[Cavemouth]` rows of `data/biomes.txt`.

The village is data, not code. It is a `generator = image` biome, and
an image biome names a **prefix**: its pictures are
`<image>_<variant>.png`, the way a wang set's tiles are. `variants`
says how many, and the world picks one per region off the world seed.

```sh
tools/seed_homelands.py           # draw the twelve and the cavemouth
tools/seed_homelands.py --check   # hold the files to the two rules
```

Two rules there are easy to break and only visible in a shot of the
whole strip, and `--check` holds the files to both:

- **The side edges of every picture must agree.** Two homelands
  regions sit side by side and nothing blends them, so every picture
  draws its outermost 10 columns identically and the seeder stamps
  them last, the way `seed_tiles.py` stamps a wang band last.
- **The village green stays open.** The wizard lands in the middle of
  the fourth region and `pond_place` digs the pond 96 cells west of
  him. Which picture that region draws depends on the seed, so *every*
  picture has to be one that can take a pond and a wizard.

## The player

`docs/player.md` is the design note: how the wizard is built, the
numbers he moves by, and what this phase leaves out. Read it before
changing `src/player.odin` or `src/sprite.odin`.
`docs/lighting.md` is the note for the light he carries, for the
fireflies over the pond, for the bang an explosion gives off, and for
the sparkle a poison throws off meeting water. Read it before changing
`src/light.odin`, `src/firefly.odin`, `src/bang.odin` or
`src/sparkle.odin`, and note the third rule below. `docs/water.md` is
the note for the pond and the water shader; read it before changing
`src/pond.odin`, `src/water.odin` or `data/shaders/water.fs`.
`docs/alchemy.md` is the note for the whole alchemy: the poison, the
water and the neutral liquid the two leave, and then the salts, the
metals and the two magics that came after. Read it before changing
`data/materials.txt`'s `[Reactions]` section, `src/sparkle.odin` or
`src/alchemy_test.odin`. **A new material and a new reaction need no
code**: thirteen materials were added to that file at once and not a
line of Odin came with them. Add the row, add the test that measures it
in the sandbox, and add the gallery room that shows it.

**Everything is a material, explosions and light included.** How
bright a thing burns (`luminosity`), how hard it pushes (`force`), how
long it lasts (`lifetime`) and whether it touches matter at all
(`state = Phantom`) are fields on a row in `data/materials.txt`, not
numbers in the code.

Two rules there are easy to break and hard to see:

- **The world is drawn to the wizard, and he is 13 cells tall.** Two
  tiles that meet share a band, and the clear channel through it
  measures 77 cells, nearly six of him. A body taller than the channel
  fits every cave and leaves none of them, and a channel only a little
  taller than the body is a tunnel he clears and cannot move in.
  `test_the_player_fits_the_world` measures the real tiles and fails
  at both ends: under `PLAYER_BODY_H + 2` he is sealed in, and under
  `PLAYER_WORLD_CHANNEL` the world has shrunk back to tunnels.
- **The drawing and the collision box are two numbers that must agree.**
  `tools/seed_wizard.py` holds the body box, `src/sprite.odin` asserts
  it matches `src/player.odin`, and `--check` holds the sheet to it.
- **So do the drawing and the orb.** `tools/seed_wizard.py` paints the
  orb on the staff, and `src/light.odin` says where the light leaves it
  and in what colour. `test_the_orb_light_starts_where_the_sheet_draws_the_orb`
  reads the sheet at the point the constants compute and fails if a
  redrawn wizard moves the orb out from under his own light.

```sh
tools/seed_wizard.py           # redraw data/sprites/wizard.png
tools/seed_wizard.py --check   # hold the file to the rules
```

## The drudge

`docs/drudge.md` is the design note: how he is built, the numbers he
moves by, and what this phase leaves out. Read it before changing
`src/drudge.odin` or `src/drudge_sprite.odin`.

He has his own sheet, drawn by his own seeder, and it keeps the same
two rules the wizard's own does, plus one more:

- **The drawing and the collision box are two numbers that must
  agree.** `tools/seed_drudge.py` holds his body box, `src/drudge_sprite.odin`
  asserts it matches `src/drudge.odin`, and `--check` holds the sheet
  to it.
- **So do the drawing and the lamp.** `tools/seed_drudge.py` paints
  the lamp at a fixed point, and `src/drudge.odin`'s `drudge_lamp_at`
  says where the light leaves it and in what colour.
  `test_the_drudge_lamp_light_starts_where_the_sheet_draws_the_lamp`
  (`src/light.odin`) reads the sheet at the point the constants compute
  and fails if a redrawn drudge moves the lamp out from under his own
  light.
- **He must spawn underground, not merely on solid ground near the
  wizard.** The first ground `drudge_place` finds that answers every
  other rule can still be the shore beside the pond, so `drudge_has_ceiling`
  additionally demands solid rock within `DRUDGE_SPAWN_CEILING` cells
  above his head. `test_the_shipped_world_places_a_drudge_underground`
  holds the shipped drudge to it.

```sh
tools/seed_drudge.py           # redraw data/sprites/drudge.png
tools/seed_drudge.py --check   # hold the file to the rules
```

A pixel editor works on a tile too, but then the save gate may report
a seam that no longer agrees, and `N` in the editor mends it.
