What we're creating: A Noita like game with classical virtue and discovered narrative. Created in Odin from scratch. Physics, chemistry, alchemy, adventure, beauty, sacrifice, tinkering, exploration, defeat, victory. Everything in the world is a material, a row in `data/materials.txt`, including things that are not obviously matter, like light and explosions. When writing code use the ponytail complexity ladder. When writing prose use Simplified Technical English. Prioritize simplicity, ease of change, end to end performance, and testability.

## Build

Run every command from the repository root, because the data paths are
relative to it.

```sh
make check              # types, and the things vet catches
make test               # the whole suite: a mark for each test
make                    # bin/the-game, bin/game-mcp, bin/shot
make bench              # bin/bench, which times a tick
make web                # web/build/index.html, the game in a browser
```

The web build needs its own toolchain, `sudo
tools/install-web-toolchain.sh`, and it holds rules the desktop build
does not: no `core:os`, no `core:testing`, no `asm`, no loop of its
own, and no `#version` in a shader. Read `docs/web.md` before adding
an import to `src/`, and run `make web` after: the desktop build will
not tell you that the browser one broke.

If `odin` is not on the PATH, install it:
`sudo tools/install-toolchain.sh` takes about half a minute and needs
the network. See `docs/toolchain.md` for what it does, and why the
Odin repository must not be cloned to get raylib.

### How loud the toolset is

A run that goes right prints its result and nothing else: the files a
build wrote, a mark for each test that passed, the PNG a shot drew.
The talk behind it is on a ladder, and every part of the toolset reads
the same rung:

```
0  the result, and nothing else            (the default)
1  a line for each piece of work
2  the detail behind each line
3  everything, the graphics trace log included
```

```sh
make V=2                   # the Makefile, and the compiler timing itself
tools/test.sh -v           # the suite, with a name beside each mark
./bin/shot biome=Lake debug=2 out=shots/lake.png
tools/seed_tiles.py --check -vv
sudo tools/install-toolchain.sh -v
GAME_DEBUG=1 ./bin/bench    # the ladder in the environment, for a whole shell
```

Every one of these runs wrong with no argument at all, or with an
argument it does not know, and prints its usage instead of guessing.

When you add a message: if a run that goes right must print it, it is
a result, and it goes to stdout with no rung. Everything else takes a
rung and goes to stderr, so a shell can keep the result and drop the
talk. `src/noise.odin` holds the ladder for the Odin side and
`tools/noise.py` for the Python side.

## Measure before you optimize

`src/prof.odin` times every phase of the tick and the frame, and counts
what a tick worked: rows stepped, cells loaded, reacts, swaps. Three
ways to read it, no tools to attach:

- `./bin/bench biome=Lake ticks=300` prints the cost of a tick and the
  shape under it: which phases the tick went to, widest first, with
  each one's share, and how much matter the tick worked.

  ```
  Lake 2048x2048: 9.901 ms a tick, over 50 ticks (checksum 0x8b9619ef8a45e51c)
  tick    Step_Rows 9.815 ms 99%  Step_Wake 0.083 ms 1%  Step_Age 0.001 ms 0%
  work    4799 rows  201122 cells  3511 hot  92753 reacts  3250 moving  48888 swaps  a tick
  ```

  The same numbers one phase to a line, for a reader who has found the
  phase and wants it exact, are at `debug=2`.
- **F3** in the game window overlays the same, averaged over the last
  second.
- A headless shot prints the whole run on exit with `profile=1`:
  `xvfb-run -a -s "-screen 0 1280x720x24" ./bin/the-game shot=shots/p.png frames=300 profile=1`

A time names the phase to look at; the counts say whether the work
itself grew or the work got slower. The checksum bench prints must not
change under an optimization: same seed, same world, same bits. It
moves when the world moves, and then the commit has to say so and say
which windows moved with it -- see "What this leaves out" at the end of
`docs/laboratory.md` for the shape of that.

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
./bin/shot seed=0x1AB biome=Gallery out=shots/museum.png  # the other world
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
to draw first), `walk` (ticks of walk before the picture, negative for
left, toward the mill), `ticks` (ticks with him standing still, which
is how to watch water go somewhere without putting him in the way of
it) and `seed` (which world to open; see "The two worlds").

```sh
./bin/the-game shot=shots/mill.png frames=2 ticks=90   # the millpond, part way through
```

Then open the PNG and look at it. `grid=1` draws the tile lattice and
the region borders, which is how to tell a shape you drew from a seam
the lattice left. Arguments are `key=value`: `out biome x y w h step
scale grid player light walk ticks ignite explode seed`. Shots are not kept
in the repository.

`player=1` lights the shot; `light=0` turns that off and draws the
world flat, which is what terrain is judged by. Underground the wizard
carries nearly all the light there is. On the surface the sky throws
the day and his orb is out -- see `docs/lighting.md`, "The day is a
biome". `walk=N` walks him N ticks first (negative
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

## Film the reel

`docs/reel.txt` is the scripted run the README's video is filmed from,
and `src/reel.odin` is the player: timed input segments driven through
the same procedures the keys drive, one tick a frame, with `skip`
segments as the cuts. `docs/toolchain.md`, "Filming the reel", holds
the commands. The run is deterministic; the tick counts are a route
tuned against the shipped seed, so a terrain change means re-tuning
the legs from where the world diverged.

## Iterate on the world

1. Change the tiles or the code.
2. `make test`.
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
| `cmd/web/` | the game in a browser: the boot, and the heap it allocates from |
| `data/rooms/` | the painted regions: the galleries, the homelands, the cavemouth |
| `data/biome_map*.png` | the two worlds: the ordinary one, and the Laboratory |
| `data/shaders/materials/` | one shader a material, and the prelude they share |
| `data/` | materials, biomes, the biome maps, the tile sets, the sprites, the shaders |
| `docs/` | the design notes and the toolchain |
| `.github/workflows/` | the release: every push to `main` builds the APK and publishes it |
| `web/` | the page, its manifest and its icons; `web/build` is what `make web` writes; `web/water-lab` is the water shader lab |
| `android/` | the APK: a manifest, one WebView, and the page in its assets |
| `tools/` | the toolchain installs, the APK build, the tile seeder, the wizard and drudge seeders, the gallery seeders, and the Laboratory map seeder |

## The page, and the APK

The same sources build twice: once for the desktop window, and once for
WebAssembly, which is how the game reaches a phone. `docs/web.md` is
the design note. Read it before changing `cmd/web/`, `web/`,
`android/`, `src/file.odin`, `src/touch.odin`, `src/check/`, or either
of the two files a target answers for itself -- `src/main_desktop.odin`
and `src/noise_desktop.odin`, with `src/noise_web.odin` opposite.

```sh
sudo tools/install-web-toolchain.sh   # emscripten, and a raylib for the web
make web                              # web/build/index.html
tools/serve_web.py                    # http://127.0.0.1:8000
node tools/play_web.mjs shots/web     # look at the page, headless
tools/build-apk.sh                    # android/build/the-game.apk
```

Three rules there are easy to break, and each is a compile that fails
on one target only:

- **No `core:os`, anywhere in package `game`.** Every file goes through
  `src/file.odin` and every line the toolset says goes through the
  ladder in `src/noise.odin`. What needs the shell lives in a file
  tagged `#+build !freestanding`.
- **No `core:testing`, for the same reason.** The tests sit in the
  files the game is made of, so they build in the browser too. They
  import `testing "check"`, which is `core:testing` on the desktop and
  four names doing nothing in the page.
- **No `asm` template outside `#+build amd64`.** The wide weight pass
  is amd64 assembly and `src/sandbox_step_wide_off.odin` answers for
  every other machine with the plain path.

Every push to `main` runs the suite, builds the page, wraps it in an
APK and publishes it. See `docs/web.md`, "The release".

## The two worlds

A seed is a world, and every binary that opens one takes `seed=N`:
`./bin/the-game`, `./bin/shot`, `./bin/bench` and `./bin/game-mcp`.
Hexadecimal counts, so `seed=0x1AB` and `seed=427` are the same world.

Every seed but one lays the ordinary map out another way: another
lattice of tiles, another six of the twelve homelands pictures. One
seed does not lay it out at all. `seed=0x1AB` opens the **Laboratory**,
which is the physics gallery and the alchemy gallery side by side at
the bottom of a cutting in the rock, and nothing else, and it is the
only way into either of them. `docs/laboratory.md` is the design note. Read it before
changing `src/laboratory.odin`, `tools/seed_laboratory.py`, or the
`[Laboratory]` section of `data/biomes.txt`.

```sh
./bin/shot seed=0x1AB biome=Gallery out=shots/gallery.png
./bin/shot seed=0x1AB biome=Alchemy ticks=600 out=shots/alchemy.png
tools/seed_laboratory.py           # draws data/biome_map_laboratory.png
tools/seed_laboratory.py --check   # holds the file to the rules
```

Three rules there are easy to break and only visible in a shot of the
whole world, and `--check` holds the map to all three:

- **The two halls share a row.** Their bedrock roofs are the only
  floor of that world, and two regions on different rows have no
  joined roof at all.
- **There is open sky the whole way up over both.** The roof is what
  the wizard walks on, and a roof with earth over it is a cellar.
- **The sky stops where the museum stops.** The light is drawn a
  square at a time and everything outside that square is black, so the
  world is laid in the middle of one: rock in the dark reads as rock,
  and sky in the dark reads as a hole in the world.

`test_the_wizard_walks_the_laboratory_into_both_galleries` plays the
world through `sim_step_player`: down one door, back out on the
jetpack, along the roof, and down the other. A change that makes the
museum unwalkable fails there.

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
  the fourth region, and which picture that region draws depends on
  the seed, so *every* picture has to be one he can land in.
- **The ground of a village is ground he can walk.** He steps up
  `PLAYER_CLIMB` (3) cells. Everything worked into the ground -- ridge,
  furrow, hedge bank, ditch, well coping -- is cut to that; what people
  built may stop him, because he jumps about twenty-eight cells and
  flies further. Growth grows *out of* the ground rather than replacing
  it, or the cell it stands on stops holding him up.

## The player

`docs/player.md` is the design note: how the wizard is built, the
numbers he moves by, and what this phase leaves out. Read it before
changing `src/player.odin` or `src/sprite.odin`.
`docs/lighting.md` is the note for the light he carries, for the
fireflies over the pond, for the bang an explosion gives off, and for
the sparkle a poison throws off meeting water. Read it before changing
`src/light.odin`, `src/firefly.odin`, `src/bang.odin` or
`src/sparkle.odin`, and note the third rule below. `docs/water.md` is
the note for the two ponds -- the still one in the caves, a tile with
its fireflies painted in it, and the millpond on the green that runs
through its own dam the moment the world starts -- and for the water
shader; read it before changing `src/pond.odin`, `src/water.odin`,
`millpond()` in `tools/seed_homelands.py` or `data/shaders/water.fs`.
`docs/water_lab.md` is the note for `web/water-lab/`, one page that runs
seventeen water shaders side by side in a browser -- the shipped one,
nine drawn as schools of art and eight as models of what water is -- and
times them; read it before drawing a new design for the water.
`docs/physics.md` is the note for the sandbox: what a cell of matter
does next, and in particular the two sections that are the fluid
simulation. "The reach is the flatness" is how far a liquid or a gas
looks along its own row for the way on, and why that one number is what
makes a pond lie level. "The head and the press" is the field a body of
liquid carries and the move that spends it, which is what levels the
two sides of an opening under the waterline and fills a standpipe off
the cistern beside it. Read both before changing
`src/sandbox_step.odin`, its vector twin `src/sandbox_step_simd.odin`,
or a `spread` in `data/materials.txt`.
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
