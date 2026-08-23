# The water

There is a pond a short walk from the point the wizard starts at, and
the water in it is drawn by a shader: the surface ripples, the depths
go dark and cold, and a net of caustics slides over the bottom. A
swarm of fireflies hangs over the mouth of the pond and is the only
light on it until he walks up with the orb.

This note says how the pond is dug, where the shader came from, what
it draws, and what the phase leaves out. `docs/lighting.md` says how
the fireflies light the place, because they are a light and belong to
the same machinery as the orb and the crystals.

## The pond is an overlay, not a biome and not a tile

A biome fills a whole region of 512 cells, so a `Lake` pixel on the
biome map is a lake and can never be a pond. A tile belongs to a whole
biome, so a pond painted into one is a pond in every region of the
Coalmine. A pond is one thing in one place, so it is neither.

`src/pond.odin` holds it. A `Pond` is six numbers — a middle, two
radiuses, and the two materials it is made of — and `pond_cell` turns
those into the material of a cell:

| Where | What |
| --- | --- |
| inside the lower half ellipse | water |
| within `POND_SHELL` (5) cells outside it | the bank, which is rock |
| in the upper half ellipse, `POND_LIP` (8) cells high | air |

So the pond is a bowl of water in a shell of rock with its mouth cut
open to the sky, whatever the tile under it was painted as. **The
shell is what makes it hold.** The play sandbox runs the water like any
other liquid; a bowl with a hole in it empties into the caves below
within a few seconds. `test_the_pond_holds_its_water_in_a_bowl_that_cannot_leak`
walks every water cell of the shipped pond and fails if any neighbour
but the one above it is neither water nor bank.

The overlay is applied in both paths that read the world:
`world_cell_at` for one cell, and `generate` once a row, over the run
of texels the pond covers and no others. It costs nothing anywhere
else, and `test_the_pond_reaches_the_world_the_same_way_down_both_paths`
holds the two paths to each other over the pond at three zooms.

## The pond is placed after the spawn is found

`world_find_spawn` puts him in the middle of the fourth homelands
region, which `[Map]` names; see `docs/homelands.md`. Failing that it
walks out from x=0 along the surface row looking for a **mouth**: ten
cells of nothing, one under the other, which is a way down into the
caves. Water is not solid, so a pond reads as a mouth, and a pond dug
before the spawn is chosen can move the wizard to the edge of it.

So the order in `sim_load` is: spawn first, then
`pond_place(world, spawn_x, spawn_y)` puts the pond `POND_AWAY` (96)
cells to his left, then the swarm gathers over it. The spawn search
also skips whatever a pond carves, so asking it a second time — which
`bin/shot` and the tests both do — gives the same answer as the first.
`test_the_pond_leaves_the_spawn_where_it_was` compares the spawn of the
world with the pond against the spawn of the same world without it, and
fails if the pond moved him.

The distance is a rule too, not a taste: the pond must open more than a
body width from his feet and less than half a play square away, so it
is neither under him nor out of reach. `test_the_pond_is_close_enough_to_the_spawn_to_walk_to`
holds both ends.

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
3. **The caustics and the surface.** Two crossing fields of sines, in
   world cells so the pattern stays with the world as the camera moves,
   warped by a third slower field so the net curves instead of forming a
   lattice, and ridged — `pow(1 - abs(w), 9)` — so what is drawn is the
   thin bright line where a wave crosses zero and not a smooth blob.
   The surface line is the same thing at depth 0, with a ripple
   travelling along it.

**The shader never lights what the light left dark.** Everything it adds
is multiplied by `lit`, taken from the brightness of the texel the CPU
already shaded. Water in the far gloom is a dark shape; water under the
fireflies shimmers; water under the orb is bright. So the one place the
look of light lives is still `light_shade`, and the shader only says
what water does with the light it is given.

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
```

`walk=N` holds a walk key for N ticks first (negative walks left, toward
the pond), `frames=N` draws N frames before the picture is taken, which
is what moves the water, and `shot=PATH` writes the PNG and closes the
window. It needs a display. On a machine with none, an X server that
draws into memory is enough:

```sh
xvfb-run -a -s "-screen 0 1280x720x24" ./bin/the-game shot=shots/water.png frames=140 walk=-40
```

`bin/shot` still needs neither, and is still the way to judge terrain.

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
- **One pond.** `World` holds room for `POND_MAX` (4) of them and the
  overlay walks them all, but the game digs one, beside the spawn.
- **GLSL 330 only.** There is no `#version 100` twin of the shader, so
  a GL ES build would fall back to flat water.
- **The water does not move the light.** Light passes through water as
  it passes through air, and the caustics are drawn on the water rather
  than cast by it onto what is under the surface.
- **Nothing else is shaded.** Lava, acid and oil are liquids too and are
  drawn flat. The depth map has one material in it; giving it more is
  the obvious next step.
