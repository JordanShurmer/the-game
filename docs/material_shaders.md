# A shader for every material

The world draws as one texture of flat cell colours, one texel a cell.
That is enough to say what a cell holds and nothing at all about what it
is made of: a cell of gold and a cell of yellow paint come out the same
colour. This pass paints over that texture, one material at a time, so
each material answers light the way the stuff it stands for does.

A material may bring one file, `data/shaders/materials/<name>.fs`, named
after itself in lower case. `Burning_Wood` brings `burning_wood.fs`. A
material that brings no file is drawn flat, as before, and costs nothing.

## What a material file holds

One procedure, and nothing else:

```glsl
vec3 shade(Surf s) { ... }
```

No `#version`, no `main`, no uniforms. The game builds the whole program
from three parts and compiles it at load:

| Part | File | What it brings |
| --- | --- | --- |
| the prelude | `_prelude.glsl` | the uniforms, the `Surf`, and the helpers |
| the material | `<name>.fs` | `vec3 shade(Surf s)` |
| the epilogue | `_main.glsl` | fills a `Surf`, throws the other cells away |

A material file may name its own constants and helpers, and it must
prefix them with the material's name (`gold_height`, `GOLD_ROUGH`), so
two materials never collide.

A material file may say how hard its surface rolls over at an edge,
before anything else in the file:

```glsl
#define M_ROLL 2.6    // metal: a small, bright band. Powder: about 1.0
```

## What the game hands the shader

`Surf` is worked out once, before `shade` is called.

| Field | What it says |
| --- | --- |
| `cell` | the world cell. It does not move when the camera does, so anything drawn from it stays put on the wall. |
| `uv` | where on the world texture the fragment lies |
| `base` | the colour the flat world drew here, lit |
| `lux` | the light the world shades by, 0 to 1 |
| `glow` | the light that fell on the cell, before the response curve |
| `depth` | how many cells of the same material stand directly over this one |
| `bury` | 0 for a lone cell, 1 deep inside a body of the material |
| `edge` | `1 - bury` |
| `n` | the way the surface faces |
| `l` | the way the light comes from |
| `top` | how much the surface faces up, 0 to 1 |
| `ao` | how much open air stands over the cell, 0 to 1 |

Two of those are the whole trick.

**`n`, the surface normal, comes from the shape of the material itself.**
A cell deep inside a body of rock faces the viewer. A cell on the rim of
that body faces out of the rim. The prelude reads that off the g-buffer
by looking at three rings of neighbours and asking which of them hold the
same material. So a body of any shape has a bevel, and light rakes across
it.

**`l`, the direction of the light, comes from the light map.** The world
is brighter toward a light, so the gradient of the light map points at
every light there is at once, mixed by how much each one gives. Nothing
has to be passed in, nothing has to be counted, and a shader written this
way follows the wizard's orb, a drudge's lamp, a fire and a crystal
without knowing that any of them exist.

## The helpers

Lighting: `m_diffuse`, `m_spec(s, gloss)`, `m_spec_aniso(s, grain, along,
across)`, `m_fresnel(s, power)`, and `M_VIEW`, which is the eye.

Grain: `m_hash`, `m_hash2`, `m_noise`, `m_fbm(p, octaves)`,
`m_ridge(p, octaves)` for folds, `m_cells(p)` for a scatter of grains or
facets, and `m_glint(cell, scale, rate, rarity)` for a grain that catches
the light for a moment.

The g-buffer, if a shader wants a neighbour the `Surf` does not hold:
`g_id`, `g_lux`, `g_glow`, `g_depth`, `g_same`, and `m_texel()`.

Finishing: **`m_dress(albedo, s)` is not optional.** It sinks the colour
into the dark and lays the warm haze over it exactly as the flat world
does. A shader that returns a colour without it lights its own cells in
an unlit cave, and the material floats out of the picture. Hand it a
reflectance, in the range the flat colour of the material sits in, and it
returns the pixel.

It is made of three, which a shader may call itself when it must:
`m_gloom(col, s.lux)`, then the haze, then `m_bloom(col, s.glow)`.

Two materials have to reach inside it.

**A material that makes its own light** adds that light *after* the
dressing, or the dark sinks the very thing that is supposed to survive
the dark. A burning coal, a lava crack and a fire all do this.

**A material darker than about a tenth reflectance takes too much haze.**
The haze is `HAZE*lux*(1 - col)`, so it is scaled by how dark the
material already is: rock, at four tenths, takes a fifth of it, and soot,
at under a tenth, takes nearly all of it. Everything then converges on
the same warm beige, and the blackest material in the world comes out the
colour of the air beside it. Cutting the haze such a material takes is
not a cheat — a thing that reflects almost nothing also swallows the
light bouncing between it and the eye. `soot.fs` shows the shape of it.
Do this only for a material that is genuinely near black, and say why in
the file.

## Looking at one material

A vein of gold four cells wide in an unlit cave says almost nothing about
the shader that drew it. The bench fills the whole view with one material
instead:

```sh
make game
xvfb-run -a -s "-screen 0 1280x720x24" \
    ./bin/the-game look=Gold shot=shots/gold.png frames=30
```

It draws the shapes a shader has to answer for — a solid body with no
edge in it, discs from one cell across to fifty, a wandering vein one
cell wide, a scatter of lone grains, and a broken face of noise — and
lights them from two fixed lamps, hard, so the picture runs from full
light at the top left to almost nothing at the bottom right. The clock is
counted in frames there, not read from the wall, so two pictures taken a
day apart may be laid over each other. `src/look.odin` holds it.

Then look at the world itself, which is the only judge that counts:

```sh
xvfb-run -a -s "-screen 0 1280x720x24" \
    ./bin/the-game shot=shots/world.png frames=40 walk=-40
```

**A shader is only ever changed by looking.** Write the file, take the
picture, open it. The file is read at load, so nothing needs building
between one picture and the next.

## What makes a material read as itself

- **Metal has no diffuse colour.** What leaves it is a reflection of the
  room, tinted. Give it a bright half and a dark half that swing across a
  few cells, and it will read as metal; shade it gently and it reads as
  paint. `gold.fs` is the worked example.
- **Rock is a diffuse surface with relief.** The colour hardly moves; the
  light does, because the face is broken.
- **Powder is many small round things.** No single normal, a soft rolled
  edge, and grain at the size of a cell or two.
- **Anything wet, molten or alive moves.** `seconds` is in the prelude.
  Everything else must be dead still, or the wall crawls.

## What it costs

One pass a material, and a material the view does not hold is never
drawn: the game marks which materials the view holds while it fills the
g-buffer, and skips the rest. The mark also boxes each material to the
cells it covers, and the pass draws only that rectangle of the window,
so a vein of gold pays for the vein and not for the screen. A fragment
a pass does own still pays for its whole neighbourhood: `m_shape` reads
the ring at three radii (24 samples), `m_sky` reads six more and
`m_light` four, about 35 g-buffer reads a fragment a pass.

**A note from profiling (2026-08): if the GPU is ever the wall, look at
`_prelude.glsl` first, not at any one material.** The per-material CPU
work and the pass rectangles are already trimmed; what remains is that
every shaded fragment recomputes its shape and light from ~35 samples.
The shape half (`m_shape`, `m_sky`) depends only on the g-buffer, not on
the material file, so it could be computed once into a second buffer and
shared by every pass, instead of once per pass per fragment. No material
file needs to change for that.
