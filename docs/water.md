# The water

There are two ponds. One is in the caves under the village, still,
sealed in its own rock, with a swarm of fireflies over it -- the
Grotto. The other is on the green fifty cells west of where the wizard
lands: a millpond over a stone dam, with a spillway cut through the
dam and a pool under it, and it is not still at all. It is drawn full,
over the head of the spillway, so the first tick of the world sends it
through the dam and down into the dry pool.

Both are the same water, drawn by the same shader: the surface
ripples, the depths go dark and cold, and a net of caustics slides
over the bottom.

This note says where the two ponds are, how the fireflies find the
first, where the shader came from, what it draws, and what the phase
leaves out. `docs/physics.md` says what makes the water move at all, and it is
worth reading first: "The reach is the flatness" for how a pond finds
its level, and "The head and the press" for how a body of it carries a
head, which is what levels the two sides of an opening under the
waterline.
`docs/lighting.md` says how the fireflies light the place, because
they are a light and belong to the same machinery as the orb and the
crystals.

## The millpond

`tools/seed_homelands.py`, `millpond()`. West to east: a pond dug into
the green with a shelving bank he can walk into, a stone dam across
it, a spillway cut clean through the foot of the dam, a pool under the
spillway drawn dry, and a slipway of stone and gravel out of the pool
into the village, which is where the track through the green ends.

The whole of it is lined in Rock, because Dirt, Loam, Gravel and Sand
are all powders heavier than water and an unlined bank walks into the
pond as soon as the sandbox reaches it: measured, an unlined pond moved
298 cells in 300 ticks and the same pond lined moved a hundred, all of
them grass at the rim.

It is drawn into one homelands picture of the twelve -- one village of
the twelve has a mill -- and the world seed decides which region draws
that picture. On the shipped seed that is the region he starts in.
`test_the_wizard_starts_within_sight_of_the_millpond` holds it there,
so a change of seed says the mill has moved rather than quietly losing
it, and
`test_the_millpond_runs_through_the_dam_and_settles_over_the_pool`
holds what it does: the pond goes through the dam, fills the pool, and
the two come to rest, each of them level, the pond standing over the
pool, and not one cell of water lost on the way.

See `docs/homelands.md`, "The millpond", for where it may go in a
village picture and the two rules that constrains.

## The Grotto is a tile

It used to be an overlay, dug beside the spawn after the spawn was
found, because the spawn was beside a cave mouth and the pond was the
one landmark the surface had. The surface is a village now and the
village is daylit, and a pond of fireflies belongs in the dark. So the
pond moved underground, and it stopped being code on the way: it is
the **Grotto**, one authored tile of the Coalmine's wang set
(`coalmine_0100_1`), painted by `tools/seed_tiles.py` beside the
Cistern and the Well — a dome of cave over a rock bowl of still water,
sealed on every side but the east, where a doorway over the waterline
joins it to the cave.

The lattice decides where its instances lie, the same as any other
tile, so every world has its own ponds in its own places and another
seed moves them. On the shipped seed one lies under the village and
another under the cavemouth, which is the one the way down walks past.

The water must not leak: the play sandbox runs it like any other
liquid, and a bowl with a hole in it empties into the caves below
within seconds. The bowl is the shell's own rock and the one doorway
is cut well over the waterline;
`test_the_grotto_holds_its_water_in_a_bowl_that_cannot_leak` walks
every water cell of the shipped tile and fails if any neighbour but
the one above it is neither water nor solid.

## The fireflies are painted in the tile too

A cell of `Firefly_Light` in a tile is not matter — a phantom can
never reach the cell grid — it is a **mark**, saying a firefly lives
here. `load_tile_png` lifts every phantom cell out of a tile as a
`Tile_Mark` and leaves the air the light hangs in, so the grid keeps
its invariant; saving a tile stamps the marks back into the file, so
an editor save cannot lose them.

`firefly_gather` walks the tile slots around the spawn, asks the
lattice which tiles lie there, and homes a fly on every firefly mark
it finds, nearest first, up to the swarm's `FIREFLY_MAX`. Nothing in
the game names the Grotto: the tile that carries firefly marks is the
pond, whichever tile that is, and a pond painted into any tile of any
biome gathers its own swarm without a line of code changing.

## What was read before the shader was written

Water shaders with published source are not scarce; water shaders with
a licence a game can ship are.

| Read | Licence | What came of it |
| --- | --- | --- |
| raylib, `examples/shaders/resources/shaders/glsl330/wave.fs` | zlib | **Taken.** The two lines that bend the texture coordinate by a cosine of one axis and a sine of the other are that shader's, and are marked as such in `data/shaders/water.fs`. |
| `elemel/water-shader`, `water.frag` | MIT | Read, not used. It cuts a wave-shaped silhouette out of a quad and is written against `gl_FragColor`, which is GLSL 1.x. |
| `tuxalin/water-shader` | MIT | Read, not used. It is a 3D ocean surface: normals, foam, a projected grid. There is no third dimension here. |
| Shadertoy "Tileable Water Caustic" (`MdlXz8`) and its Godot port | CC BY-NC-SA 3.0 | Read for the look only. The non-commercial term does not suit a game, so **none of it was copied**; the caustics here are written from ridged sines and are not that shader. |

The raylib example is the natural base: it ships with the very library
the game already links, under the same zlib licence, and the wave it
draws is exactly the part of water that a texture of cells cannot say
for itself.

## What the shader draws

The world reaches the screen as a texture of texels, one texel to one
world cell, already shaded by the light. The shader is a second pass
over that same texture. It needs to know which texels are water and how
deep each one is, and the texture cannot say, so `src/water.odin` builds
a second one that does.

**The depth map.** `water_depth_fill` walks the cells a row at a time
and keeps a run per column: a texel that is not water is 0, the first
water texel of a column is 1, the one under it is 2, and so on to 255.
That single byte is both the mask and the depth, and it is uploaded to a
one channel texture beside the world. A texel of 0 is discarded by the
shader, so everything that is not water is left exactly as the light
drew it.

From the depth the shader makes three things:

1. **The wave.** The texture coordinate is bent by the raylib wave, so
   what lies under the water — the rock of the bowl, the debris on the
   bottom — wobbles with the surface.
2. **The sink.** Deeper texels are pulled toward `DEEP`, which keeps
   less red and a little more blue, so a pond reads as a bowl and not
   as a flat blue shape. It is a multiply, never an add, so water in
   the gloom stays in the gloom.
3. **The caustics and the surface.** The net light leaves on the bottom
   of a pond is the boundary of a pattern of cells — bright curved seams
   where neighbouring lenses of surface meet — so it is drawn as one: a
   scatter of points that drift, in world cells so the pattern stays
   with the world as the camera moves, and the brightness is how close
   the texel lies to the seam between the nearest point and the next.
   Two such nets at different scales are laid over each other, and the
   whole thing dims with depth, because a lens focuses light near the
   surface and spends it there. The surface line carries a slow ripple
   and a twinkle: each short run of it has its own phase, and a hard
   `pow` keeps all but the crest of each pulse dark, so points of the
   line catch the light and let it go.
4. **The mirror.** The world above the surface, sampled upside down with
   a sideways waver and mixed in faintly, fading with depth. The sample
   is of the picture the light already drew, so a dark shore reflects as
   a dark shore; what it brings the pond is the firefly and the orb,
   inverted and wavering, which is what still water does at night.

**The shader never lights what the light left dark.** The net and the
twinkle are multiplied by `lit`, taken from the brightness of the texel
the CPU already shaded and tinted by its colour, so a glint under the
fireflies is green and one under the orb is warm. The mirror adds only
light that already stands in the picture above the water. Water in the
far gloom is a dark shape; water under the fireflies shimmers; water
under the orb is bright. So the one place the look of light lives is
still `light_shade`, and the shader only says what water does with the
light it is given.

## Where it runs, and what happens when it cannot

`app_draw_water` draws the same rectangle a second time inside
`BeginShaderMode`, and only while the game is being played:
`app_lighting` is false in both editors, where terrain is judged flat.

`water_load` returns a `Water` with `on = false` if the file is missing
or the shader will not compile, the game says so on stderr once, and
every water procedure then does nothing. **A missing shader costs the
ripples, not the game.**

## Look at it

The window is the only place the shader runs, so the window is where it
has to be judged. `bin/the-game` takes a shot of itself:

```sh
make game
./bin/the-game shot=shots/water.png frames=140 walk=-40
./bin/the-game shot=shots/mill.png frames=2 ticks=90    # the mill, part way
```

`walk=N` holds a walk key for N ticks first (negative walks left, toward
the mill), `ticks=N` stands him still and runs the world for N ticks
instead, which is how to watch water that is going somewhere without
putting him in the way of it, `frames=N` draws N frames before the
picture is taken, and `shot=PATH` writes the PNG and closes the window.
It needs a display. On a machine with none, an X server that draws into
memory is enough:

```sh
xvfb-run -a -s "-screen 0 1280x720x24" ./bin/the-game shot=shots/water.png frames=140 walk=-40
```

`bin/shot` still needs neither, and is still the way to judge terrain.

**Before a new design reaches the window there is a lab for it.**
`web/water-lab/index.html` draws the two ponds in a browser and runs
nine water shaders over them at once: this one, and eight attempts at a
new one, each committed to a school of art. Every panel is a whole
`data/shaders/water.fs` under the uniform names above, so a design goes
from the page to the game by copying it over this file. The page can
also time the nine against each other. `docs/water_lab.md` is the note
for it, and says where the browser's pond differs from the game's.

## What it costs

The depth map is one pass over the texels that are already in cache
from the shading, about 320 x 180 of them at the zoom the game opens
at, and one upload of a byte per texel. The shader itself is one
full-screen pass that discards every fragment that is not water, so it
costs what the water covers.

The swarm costs about **11 microseconds a tick** for seven fireflies,
against 19 for the orb and the trail measured in the same place. The
drift itself is under a tenth of a microsecond; the rest is the seven
small floods.

## What this phase leaves out

- **A shot draws water flat.** `bin/shot` has no GPU and no window, and
  the look lives in the shader, so a PNG from it shows the pond as the
  flat blue of the material. Use the window shot above for the water.
- **Ponds go where the lattice puts them.** The Grotto is one tile of
  the Coalmine's wang set, so the seed decides how many ponds a world
  holds and where; nothing places one by hand.
- **GLSL 330 only.** There is no `#version 100` twin of the shader, so
  a GL ES build would fall back to flat water.
- **The water does not move the light.** Light passes through water as
  it passes through air, and the caustics are drawn on the water rather
  than cast by it onto what is under the surface.
- **Nothing else is shaded.** Lava, acid and oil are liquids too and are
  drawn flat. The depth map has one material in it; giving it more is
  the obvious next step.
- **The shader does not know the water is moving.** It draws the same
  ripple over a millrace as over a still pond, because all it is
  given is how deep each texel is. What would change that is a second
  channel beside the depth saying which way and how fast the water at
  that texel went, which needs the momentum `docs/physics.md` lists
  under what the physics leaves out.
