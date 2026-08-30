# The homelands

The wizard starts in a village. Six regions of field and cottage lie
west to east along the surface row of the world, with the sky over
them and the coal under them, and east of the last of them the ground
climbs into a bluff with a mouth in its face. That mouth is the way
down, and everything the rest of the game is about is on the other
side of it.

This note says how the six regions are laid out, how twelve pictures
become six of them, where the wizard is put and why there, and the two
rules the pictures may not break.

## Six regions, twelve pictures

The homelands are a `generator = image` biome, the same generator the
two galleries use. An image biome names a **prefix**, and the pictures
under it are `<prefix>_<variant>.png`, exactly the way a wang biome's
tiles are `<prefix>_<NESW>_<variant>.png`:

```
[Homelands]
color     = 0xFF7CB342
generator = image
image     = data/rooms/homelands    # data/rooms/homelands_0.png .. _11.png
variants  = 12
fill_0    = Dirt
```

`variants` used to belong to the wang generator alone. It now says the
same thing for both: how many drawings a biome owns. A wang biome
picks one per tile square; an image biome picks one per region, and
`world_image_variant` picks it off the world seed with the same hash
`wang_tile_at` uses, so:

- the six regions of the shipped map draw six of the twelve pictures;
- another `seed` in `[Map]` draws another six;
- and the same seed always gives the same village, so a shot of it is
  a shot of what the player sees.

`test_the_homelands_regions_are_not_all_the_same_picture` holds both
ends of that: the six must not collapse to two or three, and every one
of the twelve must be able to come up at all — a picture no lattice
position can reach is a picture drawn for nothing.

The pictures are one allocation: `load_image_set` reads the whole set
into one block of cells per biome and `world_image_cells` cuts a
picture back out of it. A gallery is a set of one and reads through
the same path.

## Where the wizard starts

`[Map]` says it, rather than the code:

```
spawn_biome     = Homelands   # the wizard starts in this biome
spawn_region    = 4           # the fourth of its regions, west to east
```

`world_find_spawn` finds the fourth region of that biome, counting west
to east along the row it lies on, and then walks out from the middle of
it looking for the first place a body fits over solid ground. Out from
the middle, not in from one side, so the yard the picture keeps clear
in the middle is what he lands in and a cottage he would otherwise
stand on the roof of moves him aside instead.

The fourth of six, so the walk east to the mouth is the longer half of
the village: he passes two thirds of the fields on the way to the only
way down.

A map that names no `spawn_biome` falls back to what the world did
before there were homelands: walk out from x=0 along the surface row
looking for ten cells of nothing, one under the other, and stand
beside it. That path is still tested, and it is what a hand made map
with no village gets.

## The two rules a picture may not break

Both are held by `tools/seed_homelands.py --check`, which reads the
files back off disk, and both are only ever visible in a shot of the
whole strip.

**The side edges of every picture must agree.** Two homelands regions
sit side by side and the world does not blend them, so column 511 of
one is the neighbour of column 0 of the next. Every picture therefore
draws its outermost `EDGE` (10) columns identically: level ground at
`EDGE_GROUND`, the grass over it, and the strata under it. The seeder
stamps those columns last, after everything else is drawn, exactly the
way `tools/seed_tiles.py` stamps a wang tile's bands last — so a field
that runs into the border simply ends in a headland, and no picture
has to be drawn around the rule.

**The village green stays open.** The wizard lands in the middle of the
fourth region, and which of the twelve pictures that region draws
depends on the seed, so *every* picture has to be one he can land in:

| Span | What may be there |
| --- | --- |
| `GREEN_X0`..`GREEN_X1` | no Brick, no Thatch, no Wheat: no building and no crop |
| the yard | soil, grass and the gravel track, so there is always somewhere to stand |

That is why the middle of every picture is pasture with a track across
it. It is not an oversight; it is where he lands. The yard is held
tighter than the rest of the green: the green forbids only what people
built -- no Brick, no Thatch, no Wheat -- while the yard forbids
everything but soil, grass, gravel and the rock and coal under them.
Water is legal on the green and not in the yard, which is exactly the
room the millpond needs.

## The millpond

One village of the twelve has a mill, and the mill is the only water on
the surface of the world. `millpond()` in the seeder draws it, west to
east: a pond dug into the green with a shelving bank, a stone dam
across it, a spillway cut clean through the foot of the dam, a pool
under the spillway drawn dry, and a slipway out of the pool that the
track through the village runs down. The pond is drawn full, five cells
over the head of the spillway, so the first tick of the world sends it
through the dam and down into the pool.

It is at local x 96 to 206, which is west of the yard and inside the
green. That span is the one place in a picture where it can go, and the
reason is in the two spans above: the yard (232 to 280) may hold no
water at any depth, and the plot spans east and west of the green are
full of what people built. The site is levelled first -- a mill site is
the one place in a village where the ground was worked flat on purpose
-- and `level_site` ramps the ground back to the line it had at each
end, a cell a column, so no step out of the works is more than a
wizard's stride.

Three things about it that are easy to get wrong:

- **The spillway is a hole through the dam, not a hole in it.** The
  picture is a section: the dam's seven columns are its thickness, so
  an opening has to be cut across all seven or the water never reaches
  it. Two drafts of this drew a neat notch in the middle of the dam and
  watched the pond sit there for fifteen hundred ticks.
- **The bowl is Rock, all of it.** Dirt, Loam, Gravel and Sand are
  powders heavier than water, so an unlined bank walks into the pond as
  soon as the sandbox reaches it.
- **`--check` will not catch a pond.** `check_walkable` only faults on
  a step made of Grass, Dirt, Loam, Gravel or Sand, so a stone-faced
  dam or coping of any height passes it for free. Judge the mill by the
  picture and by walking it. The Odin tests in `src/pond.odin` are the
  gate that does hold it.

`docs/water.md` says what the water then does, and
`docs/physics.md`, "The reach is the flatness", says why it does it.

## The strata, and why nothing under the fields is hollow

The homelands sit on deep earth: topsoil, subsoil with stones turned up
in it, a band of gravel, and the rock that roofs the coalmine in the
region below. Nothing in a homelands picture is hollow except a well
shaft, and there is no way down through a field.

That is deliberate. If the fields were cave underneath, the mouth east
of them would be one way down among many and the walk to it would be
pointless. `stratum_at` is shared by the drawing and by the gate, so
the strata a picture holds and the strata its edge columns hold can
never drift apart.

## The cavemouth

One region, one picture, immediately east of the last homeland.
`test_the_caves_open_east_of_the_last_homeland` holds all of it:

- the pixel east of the last homeland is the cavemouth, and
- an open way runs from the last field, in through the mouth, and out
  of the bottom of the region into the coal under it.

The picture's west edge holds the same profile every homeland does, so
the last field runs straight into it. From there the ground climbs the
whole height of the region — at the east edge it stands at the very top
of the picture, which is exactly where the Coalmine region beside it
starts, so the two meet with no step. It does not climb as a slope: it
starts as a scarp `FACE` cells high, because a mouth needs a face to
open in and a slope has none.

The passage behind the mouth goes in level at the height of the fields,
then back and down under the hill, widening the whole way into a cavern
that is open along the whole bottom edge of the region. Open along the
whole edge, because the Coalmine tile under it is whichever one the
lattice lays there, and half of any of them is solid.

## The ground of a village is ground a wizard can walk

He steps up `PLAYER_CLIMB` (3) cells and jumps about twenty-eight. So
everything worked into the ground of a homeland -- a ridge, a furrow, a
hedge bank, a ditch, the coping of a well -- is cut to three, and what
people *built* -- a wall, a roof, a fence, a stack of cut wood -- may
stop him, because he goes over it.

`check_walkable` in the seeder holds every picture to that: it walks
the surface of each and fails on any rise over three cells made of
ground. `test_walking_east_out_of_the_village_gets_him_somewhere` asks
the same of the running game, coarsely: twenty seconds of walking and
jumping east must take him ninety cells.

Both exist because the first draft broke it everywhere at once. Furrows
four cells under ridges four cells proud, every dozen cells, the length
of every field; a well built to the waist standing across the road out
of the village; and crops that were `state = Solid`, so a field of
wheat was a wall eleven cells high. Holding one key walked him
forty-four cells and then nothing.

Three rules came out of fixing it, and they are the ones to keep:

- **Growth grows out of the ground and does not replace it.** A stalk
  written into the cell it stands on takes the ground out from under
  itself -- Wheat is Brush, which he walks through, so what he then
  walks on is the loam a cell lower, and a stook puts a step in the
  middle of a field that the field never had.
- **Grass stands on the soil line rather than being the top of it.**
  Grown the other way, every solid thing laid at the ground line stands
  on a three-cell pedestal, and walking off a meadow onto a footpath is
  a step he cannot take.
- **Nothing is levelled after the fact.** Shaving a column against a
  neighbour that is itself still to be shaved walks a whole hillside
  down to the level of its lowest point; an attempt at it dug a pit
  through the middle of a field. Each thing is cut to the step where it
  is drawn.

## What the village is made of

Five materials came with it, and not a line of Odin came with them:

| Material | What it is | How it burns |
| --- | --- | --- |
| `Loam` | tilled earth, the ridges of a field | not at all |
| `Grass` | the skin over the pasture, and the hedges | catches quickly, leaves bare Dirt |
| `Wheat` | the standing crop | the most flammable thing in the world |
| `Thatch` | a roof of reed and straw | stands like timber, burns like a crop |
| `Brick` | fired clay, the walls of a house | not at all |

And `Water`, which is not new and is not the village's, but the mill is
where it first stands in the daylight.

Grass and Wheat are `state = Brush`, which is new with the homelands:
matter that holds its cell against sand and water the way a solid does,
and burns and crumbles like anything else, but is too slight to stop a
man. It is a state and not a flag because it is a way of being matter,
the same as being a powder is. Without it a field is a wall.

So a homeland burns from the crop up, and the brick is what a fire
stops against. The fallow strips between the plots are the firebreak,
and they are there for that reason as much as for the look of them.

Each brings a shader, in `data/shaders/materials/`. Two of them lean on
something the prelude already hands every shader and neither needed a
new field for it:

- `wheat.fs` reads `s.depth` — how many cells of the same material
  stand over this one — to know where the ear of a stalk is. Under
  `WHEAT_EAR` cells of depth it draws grain and awns; below that it
  draws straw. One row in `data/materials.txt` is the whole crop.
- `thatch.fs` reads `s.n` to know which way the roof slopes, and lays
  its courses across that. So the near slope, the far slope and a rick
  standing in a field all come out right, and the file knows about none
  of them.

## Drawing them

```sh
tools/seed_homelands.py           # draws the twelve and the cavemouth
tools/seed_homelands.py --check   # holds the files on disk to the rules
```

Then look at them. `bin/shot` draws the authored world through the same
path the game window draws through, and `light=0` draws it flat, which
is what terrain is judged by:

```sh
./bin/shot x=-2560 y=-2560 w=512 h=340 light=0 scale=1 out=shots/home.png
./bin/shot x=-4096 y=-2620 w=896 h=300 step=4 light=0 out=shots/strip.png
./bin/shot x=-1152 y=-2620 w=768 h=500 light=0 scale=1 out=shots/mouth.png
./bin/shot player=1 out=shots/wizard.png
```

The material shaders need a GPU, so `bin/shot` cannot draw them. The
bench is what a shader is judged by:

```sh
xvfb-run -a -s "-screen 0 1280x720x24" ./bin/the-game look=Wheat shot=shots/wheat.png frames=25
```

## What this phase leaves out

- **There is no night.** The day is one number that never changes, and
  the village is always at noon. See `docs/lighting.md`, "The day is a
  biome", for how the sky throws it and why the orb goes out under it.
- **Nobody lives there.** The cottages are empty and the fields are
  untended. The drudge is the only other body in the world and he is
  placed underground.
- **Nothing grows and nothing is harvested.** Wheat is a material that
  stands there and burns. There is no season and no yield.
