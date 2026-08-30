# The water lab

`web/water-lab/index.html` is one page that draws a pond nine times, once
for each of nine attempts at the water shader, and runs all nine at once
in a browser. Plate I is the shader the game ships. The eight after it
are new designs, and each one is committed to a school of art rather
than to realism: a woodblock print, a heap of impressionist marks, an
ink wash, a stained glass window, an eight colour demake, a photograph,
a painted cel, and a neon cabinet.

Nothing in it is in the game. It is a place to judge a look before
writing it into `data/shaders/water.fs`, because the look lives in the
shader and a shader can only be judged against a picture.

Read `docs/water.md` first. It says what the water pass is given and
what the shipped shader does with it; this note only says how the page
puts the same thing in a browser.

## Looking at it

The page is one file, with no build step, no libraries and no server:

```sh
xdg-open web/water-lab/index.html          # or open it in any browser
```

It needs WebGL 2. Without it the page says so and draws nothing.

Three controls sit under the title. **Pond** swaps the Grotto at night
for the millpond in daylight, which is the harder test: the night pond
hides a plate's mistakes and the day pond does not. **Zoom** is the
game's own zoom, the cells a panel shows. **Motion** holds the clock,
which is how to compare two plates on the same frame. A click on any
panel opens it large.

## The contract

Each plate gets exactly what `water_begin` gives the game's shader, under
the same names: `texture0`, the world already shaded by the light;
`mask`, one byte a texel holding the depth of the water there, which is
0 where there is none; and `size`, `origin`, `step_cells` and `seconds`.

So **a plate is a whole `data/shaders/water.fs`**. Press *Copy* on one,
write it over that file, and the game draws it. No shader on the page
names a version, for the same reason no shader in the repository does:
the loader puts the header on, and it is the one line that differs
between the desktop build and the browser build. See
`docs/web.md`, "The shaders".

The page holds to that contract in the way it draws, too. It runs one
WebGL context for the whole page, draws the pond into a framebuffer of
cells, and then draws each plate as a second full-screen pass over it,
which is what `app_draw_water` does inside `BeginShaderMode`.

## The pond is drawn in the browser

The game cannot hand a web page a world, so the page makes one:
`fs-scene` paints the two ponds `docs/water.md` describes, cell by cell,
out of the colours in `data/materials.txt`, and writes the depth byte
beside the colour with the rule `water_depth_fill` uses -- 0 for no
water, else the count of water cells standing on this one.

It is a stand-in, and it differs from the game in three ways that matter
when reading a plate:

- **The light is eight lamps, not a flood.** Six fireflies, the orb on
  the shore and one crystal in the bed of the Grotto; the sun and the
  open sky for the millpond. Each falls away by `e` over its reach.
  `light_shade` casts a real flood over real terrain and will not agree
  with this in detail.
- **The terrain is a formula.** Two curves for the roof and the bed of
  the Grotto; a shelving bank, a dam and a spillway for the millpond.
  No sandbox runs, so the water never moves and never levels.
- **The camera holds still**, so nothing shows how a pattern locked to
  the world behaves when the view moves.

Judge the school of art in the browser. Judge the shader in the window,
with `./bin/the-game shot=shots/water.png`.

## What they cost

The page can time them. **Measure on this machine** draws each plate ten
times at 1280 x 720 with the page's own drawing held still, takes the
best of two runs, and reads one pixel back to make the driver finish
before the clock is read. It reports the milliseconds a pass takes, the
share of the view the water covered, and each plate against Plate I.

Two numbers beside it are read off the shader source itself, so they
cannot drift from the code on the page: the texture reads one fragment
makes, with the reads inside a loop counted once for each turn of it,
and the lines that are neither blank nor comment.

The draw count is not one of the numbers, because it is one, for all
nine. No plate adds a pass, a framebuffer, a mipmap or an upload. What
differs is the work inside a water fragment, and the discard means only
the water on screen is charged for it.

## What this leaves out

- **Nothing here is chosen.** The page compares; it does not decide.
- **One material.** The depth map has water in it and nothing else, so
  no plate says anything about lava, acid or oil.
- **No sandbox.** The water in the page is a shape, not a fluid, so no
  plate can be judged on what it does with water that is moving --
  which is the thing `docs/water.md` lists first under what the shipped
  shader does not know.
- **The bench is a browser's.** It measures this machine's driver
  through WebGL, not the game's OpenGL. Read the order, not the
  milliseconds.
