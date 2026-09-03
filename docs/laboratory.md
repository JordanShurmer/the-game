# The Laboratory

The two galleries are a museum, and a museum does not belong in the
middle of a coal seam. It now has a world of its own.

A seed opens a world. Every seed but one opens the ordinary world:
the village, the mouth east of it, the coal and the lake and the deep
rock under all of it, drawn one way or another way but always the same
places. One seed opens the Laboratory instead — the physics gallery and
the alchemy gallery side by side at the bottom of a cutting in the
rock, their two bedrock roofs joined into one floor, and nothing else
in the world at all.

```sh
./bin/the-game seed=0x1AB
```

This note says what a seed is now, how one seed comes to open another
map, what the Laboratory is made of, and how the wizard walks it.

## A seed is a world

`[Map]` in `data/biomes.txt` names the seed the game starts on:

```
[Map]
image           = data/biome_map.png
seed            = 20260818    # lays out the tile lattice
spawn_biome     = Homelands
spawn_region    = 4
```

Every binary that opens a world now takes `seed=N` and uses it in place
of that one:

```sh
./bin/the-game seed=7
./bin/shot seed=7 biome=Coalmine out=shots/other.png
./bin/bench seed=7 biome=Coalmine
./bin/game-mcp seed=7
```

The seed is what the world is drawn from, and it was already reaching
two places: `wang_tile_at` takes it to pick which tile of a set each
square of the lattice draws, and `world_image_variant` takes it to pick
which of an image biome's pictures each of its regions draws. So
another seed is another lattice under the village and another six of
the twelve homelands pictures over it — another drawing of the same
map. `test_a_seed_draws_one_world_and_two_seeds_draw_two` holds both
halves of that: one seed twice is the same world, and two seeds are not.

The seed reaches the light as well, because `light_make` seeds the
twinkle of the crystals he leaves behind him.

It is not the sandbox seed. A sandbox is opened on a rectangle of the
world with a seed of its own, which decides the sift of a brush and the
scatter of a dig, and `world_status` prints the two on separate lines
for that reason. The world seed says what the rectangle is made of; the
sandbox seed says what happens to it next.

## One seed opens another map

`[Laboratory]` is the second reserved section of `data/biomes.txt`, and
like `[Map]` it is a world rather than a biome:

```
[Laboratory]
seed         = 0x1AB
image        = data/biome_map_laboratory.png
spawn_biome  = Gallery        # he lands on its roof, between the two doors
spawn_region = 1
```

`0x1AB` is LAB, in the one alphabet a number has. It is 427 in decimal
and `seed=427` opens the same world; the game says which world it
opened, and its seed, on the first line of the heads up display.

A seed that cannot be read is refused rather than defaulted, by all
four binaries and by the loader reading `data/biomes.txt`, and
`parse_seed` in `src/laboratory.odin` is the one procedure that reads
one. It takes the grammar `core:strconv` takes and refuses one thing
more: a number too big for a `u64`. The library parser wraps such a
number, reports it good, and hands back the low 64 bits, so
`seed=18446744073709552043` — which is 2^64 + 427 — used to open the
Laboratory. A number that is LAB in no alphabet must not open the
museum.

Two things a seed can change, and the resolution of both is one
procedure in `src/laboratory.odin`:

```odin
World_Layout :: struct {
	map_image_path: string,
	spawn_biome:    Biome_Id,
	spawn_region:   i32,
}

world_layout :: proc(table: Biome_Table, seed: u64) -> World_Layout
```

Everything that asks where the map is, or where the wizard starts, asks
that: `sim_load` loads the map picture it names, `world_find_spawn_region`
counts to the region it names, and the world editor saves back to the
picture it names, so a map edited in the Laboratory saves the
Laboratory. Nothing else in the game knows there is more than one world.

A `[Laboratory]` with a seed and no picture would quietly open the
ordinary map under the wrong name, so the loader refuses it. A missing
`data/biome_map_laboratory.png` is a hard error rather than a starter
map, because the file is authored data and a starter map painted over
it would be the wrong world under the right name.

## What the Laboratory is made of

The map is 16 by 16 pixels drawn against the same origin as the
ordinary one, so a map pixel is a region of 512 world cells there too.

| | |
| --- | --- |
| map pixels (9,0) and (9,1), (10,0) and (10,1) | `Sky`, which is a light and throws the day: the cutting |
| map pixel (9,2) | `Gallery`, the physics gallery: world x 512 to 1023, y -3072 to -2561 |
| map pixel (10,2) | `Alchemy`, the alchemy gallery: world x 1024 to 1535, same rows |
| everything else | `Deep_Rock` |

So the museum is 1024 cells across and 512 down, the cutting over it is
1024 across and 1024 deep, and rock is everything else in every
direction.

`tools/seed_laboratory.py` draws the picture and `--check` holds it to
five rules, of which three are the shape of the place:

- **The halls share a row.** Two regions on the same row have joined
  roofs; two on different rows have none, and there would be no way
  from one to the other.
- **There is open sky the whole way up over both.** The roof is what
  the wizard stands on, and a roof with earth over it is a cellar.
- **Everything else is the rock the museum is cut into**, the sky
  included: the sky stops where the museum stops.

```sh
tools/seed_laboratory.py           # draws data/biome_map_laboratory.png
tools/seed_laboratory.py --check   # holds the file to the rules
tools/seed_laboratory.py --check --out other.png   # holds a candidate to them
```

The five are rules about a picture, so `--out` may hand `--check` any
picture and get an answer about it. One more question is asked of the
shipped map alone, and only when `--out` is not given: whether
`[Laboratory]` points at it at all. That is a question about the data
file rather than about the picture, and asking it of a copy in `/tmp`
would fail every candidate for being a candidate.

## Why it sits where it sits

When this was laid out, the light was drawn a square 2048 cells on a
side at a time, snapped to a grid of that size, and everything
outside the square the wizard was in was black. World x 0 to 2047 by
y -4096 to -2049 was one of those squares. The light is the whole map
now (`docs/lighting.md`) and the edge is gone, but the layout below
was made for it and still reads well, so it stays.

The museum used to be at world x 0 to 1023, y -2560 to -2049, which is
the corner of that square, so its west wall and its floor lay along two
edges of the light. Standing at the physics door, half the window was
the black beyond the edge, and the black stood where the day should
have been.

It is laid in the middle of a square now: 512 cells of lit rock west of
it, 512 east, 512 under it, and the cutting filling the rest above.
The one
edge with no margin is the top of the cutting, and one tank of fuel
lifts him about 260 cells of the 1024 he would need to reach it.

That move is why the two gallery notes give the rooms coordinates they
did not give before. A room of the physics gallery is at world x
`512 + 128 * col`, y `-3072 + 128 * row`, and a room of the alchemy
gallery at x `1024 + 128 * col`, same rows, counting 1 to 16 in reading
order.

The sky stops where the museum stops for the same reason. Rock in the
dark reads as rock, because that is what unlit rock looks like; sky in
the dark reads as a hole in the world.

## The two doors

Neither gallery has a door in its side. Every gallery is painted by
`tools/museum.py`, and one of the three rules that module holds a
gallery to is that the outer border of its picture is bedrock apart
from the entrance shaft in the top edge. So the museum is entered from
above, and it has exactly two ways in: the two shafts, 4 to 23 cells in
from the west side of each gallery's own picture.

On this map that puts the physics door at world x 516 to 535 and the
alchemy door at x 1028 to 1047.

The wizard lands between them. `spawn_biome = Gallery` sends
`world_find_ground_in_region` down the middle of the physics gallery's
region, the first solid cell it meets is the roof, and the middle of
that region is world x 768 — about 240 cells west to one door and 260
east to the other. He is standing on the museum with a hall under each
foot and a door either way.

`test_the_museum_roof_has_one_door_a_hall_and_nothing_else` walks the
whole roof line and counts the holes in it, so a third hole, or a
missing one, is a failed test rather than a surprise.

## Walking it

`test_the_wizard_walks_the_laboratory_into_both_galleries` is the
navigability of this world written down. It plays the world through
`sim_step_player`, which is the procedure the keys drive, so nothing in
it is staged:

1. hold left, off the landing and down the physics door;
2. keep holding left, to the floor of room 1, under the door he came in by;
3. hold jump: one tank of fuel lifts him the 120 cells out of a hall;
4. hold jump and right, clear of the door, and down onto the roof;
5. hold right and shift, along the roof to the alchemy door, and in.

It walks the painted world with no sandbox over it, because the
question it asks is whether the museum can be walked and not what its
liquids do once they start moving. What they do is measured in
`src/alchemy_test.odin` and looked at in a shot.

## The museum keeps nobody

A drudge stands on the first ground near the wizard that has rock over
it. In the ordinary world that is a cave under the village. In the
Laboratory every such spot is inside a gallery room, and one pot thrown
in there spills over the one thing that room is built to show, so the
Laboratory places no drudge at all. There are no fireflies either, and
that one needs no rule: a firefly is a mark painted in a wang tile, and
this world has no wang biome in it.

## Looking at it

```sh
make shot
./bin/shot seed=0x1AB biome=Gallery out=shots/gallery.png            # the physics gallery
./bin/shot seed=0x1AB biome=Alchemy ticks=600 out=shots/alchemy.png  # the alchemy one, running
./bin/shot seed=0x1AB player=1 out=shots/landing.png                 # where he lands
./bin/shot seed=0x1AB x=0 y=-4096 w=342 h=342 step=6 out=shots/lab.png      # the whole world
```

That last one is the whole world in one picture: the museum at the
bottom of the cutting, and lit rock all round both. Every shot command in
`docs/physics.md` and `docs/alchemy.md` wants `seed=0x1AB` in front of
it, because that is the world those rectangles are in.

Without the seed, `biome=Gallery` says so:

```
Gallery is not painted on the map this seed opens; try seed=0x1AB (see
[Laboratory] in data/biomes.txt)
```

The seed in that line is read off `[Laboratory]`, not written into the
message, so it cannot name a world the file no longer holds. From
inside the Laboratory the same message names the way back instead, and
`bin/shot`, `bin/bench` and the MCP server all give it: a biome the map
in hand does not paint has no origin, and a tool that reaches for world
(0,0) under the name it was asked for is worse than one that stops.

## What this leaves out

The ordinary world has no way into the Laboratory and is not supposed
to have one: they are two worlds, not two places. Map pixels (8,3) and
(9,3) of `data/biome_map.png`, where the two galleries used to be, are
plain coal again, which is what their neighbours were on every side.

**One bench number moved with them, and it is meant to.** AGENTS.md
says the checksum `bin/bench` prints must not change under an
optimization; this was not one. `bin/bench biome=Coalmine` opens at the
first Coalmine pixel, which is (7,3), world (-512,-2560), and 2048
cells square from there reaches x 1535 — so the default window swallows
both regions the galleries used to fill, and its checksum went from
`0x487a28f8d3e428db` to `0x8a29bb41521ac65f`. `size=512` stops at x -1
and is unchanged, `size=1024` reaches x 511 and is not, which is the
whole of the difference. Lake, Sandcave, Oilfield and Magma are
untouched, and so is the shipped reel: it runs its 34 segments to the
same landing, `-685,-1756`, on either side of the change.

There is one other world and the loader knows its name. A third would
be the point at which `[Laboratory]` should stop being a section and
start being a list, and not before.
