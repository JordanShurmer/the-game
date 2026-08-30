# The Laboratory

The two galleries are a museum, and a museum does not belong in the
middle of a coal seam. It now has a world of its own.

A seed opens a world. Every seed but one opens the ordinary world:
the village, the mouth east of it, the coal and the lake and the deep
rock under all of it, drawn one way or another way but always the same
places. One seed opens the Laboratory instead — the physics gallery
and the alchemy gallery side by side under an open sky, their two
bedrock roofs joined into one floor, and rock in every other direction.

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
ordinary one, so a room of a gallery keeps the world coordinates every
other note already gives it.

| | |
| --- | --- |
| map pixels (0,0) to (15,2) | `Sky`, which is a light and throws the day |
| map pixel (8,3) | `Gallery`, the physics gallery: world x 0 to 511, y -2560 to -2049 |
| map pixel (9,3) | `Alchemy`, the alchemy gallery: world x 512 to 1023, same rows |
| everything else | `Deep_Rock` |

The rock is flush with the roofs, so the roof of the museum and the
ground beside it are one surface at world y -2560, and the wizard can
walk off the museum onto the rock and back.

`tools/seed_laboratory.py` draws the picture and `--check` holds it to
five rules, of which three are the shape of the place:

- **The halls share a row.** Two regions on the same row have joined
  roofs; two on different rows have none, and there would be no way
  from one to the other.
- **There is open sky the whole way up over both.** The roof is what
  the wizard stands on, and a roof with earth over it is a cellar.
- **Everything else is the ground the museum is sunk in.**

```sh
tools/seed_laboratory.py           # draws data/biome_map_laboratory.png
tools/seed_laboratory.py --check   # holds the file to the rules
```

## The two doors

Neither gallery has a door in its side. Every gallery is painted by
`tools/museum.py`, and one of the three rules that module holds a
gallery to is that the outer border of its picture is bedrock apart
from the entrance shaft in the top edge. So the museum is entered from
above, and it has exactly two ways in: the two shafts, 4 to 24 cells in
from the west side of each gallery's own picture.

On this map that puts the physics door at world x 4 to 23 and the
alchemy door at x 516 to 535.

The wizard lands between them. `spawn_biome = Gallery` sends
`world_find_ground_in_region` down the middle of the physics gallery's
region, the first solid cell it meets is the roof, and the middle of
that region is world x 256 — about 240 cells west to one door and 260
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
./bin/shot seed=0x1AB x=-256 y=-2816 w=384 h=256 step=5 out=shots/lab.png   # the whole world
```

The whole world in one picture is four regions across and one down, so
`step=5` holds it. Every shot command in `docs/physics.md` and
`docs/alchemy.md` still names the same rectangle it always did; it
wants `seed=0x1AB` in front of it now, because that is the world those
rectangles are in.

Without the seed, `biome=Gallery` says so:

```
Gallery is not painted on the map this seed opens; the galleries want
seed=0x1AB (see [Laboratory] in data/biomes.txt)
```

## What this leaves out

The ordinary world has no way into the Laboratory and is not supposed
to have one: they are two worlds, not two places. Map pixels (8,3) and
(9,3) of `data/biome_map.png` are plain coal again, which is what their
neighbours were on every side.

There is one other world and the loader knows its name. A third would
be the point at which `[Laboratory]` should stop being a section and
start being a list, and not before.
