# Alchemy

The first alchemy of the world: a poison, water, and what the two
make of each other. This note says what the materials are, what the
mix does, how the light of it is drawn, and where to walk through it.

Read `docs/physics.md` for the sandbox and the reaction table this
builds on, and `docs/lighting.md` for the rule every light in this
world obeys.

## The two liquids

Everything in the world is a material, so alchemy is three rows in
`data/materials.txt` and two rows in `[Reactions]`. The names are Old
English, because the world names its matter the way it names its
places.

| Material | Old English | What it is |
| --- | --- | --- |
| `Attor` | *ator*, *attor*: poison, venom | A toxic liquid. It poisons what it touches and drowns what it covers |
| `Smylt` | *smylte*: calm, still, serene | The neutral liquid the mix leaves. It does nothing at all, which is the point of it |
| `Sparkle` | — | A dot of light the mix throws off. It rises, flashes, and is gone |

`Attor` is a little heavier than water and a little lighter than
`Toxic_Sludge`, so a pool of it lies under water and over oil, and the
density rooms of the gallery read left to right without a new rule.
`Smylt` is heavier than water again by a hair, so the liquid the mix
leaves settles under the water that has not reacted yet, and the
reaction front stays where the eye can find it.

`Sparkle` is `state = Special`, the state `Fire` and `Blast` are: it
lives in a cell, it rises, and it decays. Its `lifetime` is 10 ticks,
a sixth of a second, and it decays to `Air`. It has no `contact` and
no `immersion`, so it burns nothing, wets nothing, and poisons
nothing. It is light and nothing else.

## The mix

```
Attor + Water -> Sparkle + Smylt   170
Attor + Water -> Smylt   + Smylt    86
```

Two rows for one pair. This is new: see "A chain of rows" below.

The arithmetic the two rows hold is the whole design of the mix. A
reaction takes two cells and leaves two cells. The first row leaves
one sparkle and one measure of neutral liquid; the second leaves two
measures and no light. 170 and 86 add to 256, so the pair always
reacts, and the first row takes 170 of every 256 rolls:

| | Share | Of six cells |
| --- | --- | --- |
| `Sparkle` | 170/512 = 0.332 | 2 |
| `Smylt` | 342/512 = 0.668 | 4 |

Three parts of `Attor` and three parts of water are six cells. Four
of them are left as `Smylt`, and the other two flash and are gone. One
part in three is light and two parts in three are liquid, which is
what the eye is meant to read: **the pool loses a third of itself to
the sparks**.

1/3 is not reachable in 256ths, and 170/512 is 0.4% under it. The test
`test_the_mix_leaves_two_parts_in_three` measures the real sandbox and
holds the share to 1/3 within a percent, so a changed number in the
table is caught by the count and not by a reading of it.

### A chain of rows

Before this, `[Reactions]` held one row for a pair of materials and a
second row for the same pair wrote over the first. Now a pair may name
as many rows as it likes, and they are tried in the order they are
written.

A cell rolls **once** for the pair, and the chances of the rows add up
along the chain. A chain that adds to 256 or more always fires; a
chain that adds to less than 256 leaves the rest of the rolls doing
nothing, exactly the way one row with a chance under 255 does today.
So a single row behaves as it always did, and nothing in the table
changes meaning.

The loader refuses a chain no reader could follow: a row after a row
that already carries the chain past 255 can never fire, and that is a
hard error naming both lines, not a silent dead row.

## The light of a sparkle

Every light in the world is a material and the light of this one is
`Sparkle`, `luminosity` 190. The order the lights burn in gains a
rung, and `test_the_lights_of_the_world_are_ordered` holds it:

```
Blast 255 >= Orb_Light 255 > Sparkle 190 > Light_Crystal 168 > Firefly_Light 96
```

A sparkle burns brighter than the trail the wizard leaves and it never
lights a room, because brightness is not reach. `SPARKLE_REACH` is 5
samples, 20 cells, the smallest light in the world; a bang reaches 34
and the orb 27. `test_a_sparkle_is_the_smallest_light_in_the_world`
holds it under every other light there is. What the eye sees is a
white pinpoint with a haze the width of a fingertip around it, so a
hundred of them over a basin read as a hundred sparks and not as one
lamp.

### The ring

The sparkles the world lights are a ring on the sandbox, beside the
ring of bangs, and it is built the same way for the same reason: the
cells write themselves, and the ring is what the light throws and the
eye draws.

- `SPARKLE_MAX` is 64. A mix that makes a thousand sparkles in a tick
  still costs 64 floods, because the ring keeps the newest and drops
  the rest. The cells are all still there; only the light is capped.
- A sparkle in the ring holds the light box it lit last tick
  (`lx`, `ly`, `lit`), the way a firefly does, so a slot written over
  in the middle of its life clears the light it left. A bang cannot do
  this, because 16 slots and a crater outlive each other; 64 slots and
  10 ticks do not.
- `spark_age` runs in `sandbox_step`, beside `bang_age`.
- Each sparkle carries a seed byte, and its brightness is jittered
  0.72 to 1.0 by it, so a swarm shimmers instead of pulsing as one.
- `spark_power` holds near the peak for the first third of the life
  and falls away as the square after it, the way `bang_power` does: it
  snaps on and gutters out.

### What it costs

A sparkle is three cheap things: a cell that decays in 10 ticks, a
slot in a fixed ring, and a light flood 11 samples square. 64 floods
is about 8000 samples a tick, against the 5000 one bang costs. There
is no allocation and no list that grows.

`make bench` before and after must be read, and the number recorded in
this note the way `docs/physics.md` records its own.

## The alchemy gallery

A second hand painted region, east of the physics gallery: map pixel
(9,3), world x 512 to 1023, y -2560 to -2049. Same shape as the first
one, and drawn by the same code: sixteen rooms in a four by four grid,
each 128 cells square including its bedrock wall, doors between the
rooms of a row, shafts down the ends.

`tools/seed_gallery.py` and the new `tools/seed_alchemy.py` share
`tools/museum.py`: the canvas, the room, the doors, the shafts, the
PNG reader and writer, and the three rules `--check` holds. Each
gallery is then its own file with its own room table and nothing else.
Moving that code must not move a pixel: `data/rooms/gallery.png` is
regenerated and has to come back byte for byte the same file.

The first six rooms are the alchemy. The other ten are halls with
plinths, walled and doored and empty, because this gallery is meant to
be filled as the alchemy grows.

| # | Room | What it shows | What starts it |
| --- | --- | --- | --- |
| 1 | Attor | A tank of poison pours down a stair into a basin. No water, no light: this is the liquid on its own | gravity |
| 2 | The mix | An Attor tap and a water tap over one basin. They meet in the air, the sparks flash, and Smylt pools under them | gravity |
| 3 | The measure | Three parts Attor sealed over three parts water in a graduated tube, against a bedrock scale. What is left stands at four | gravity |
| 4 | The rain | Water drips through a perforated bedrock ceiling into a shallow pool of Attor: a slow, unending field of sparks | gravity |
| 5 | Layers | Oil, water, Smylt and Attor pour into one tank and settle in four bands, in the order the densities say | gravity |
| 6 | The dark | A sealed chamber with one drip in the middle of it. The sparks are the only light there is | gravity |
| 7-16 | Halls | Empty, walled, doored, with a plinth. Room for what comes next | — |

Room 6 is the room this whole note is for. Shoot it with the lighting
on and nothing else in the frame, and the sparks either read as
fireflies over a dark pool or the numbers above are wrong.

## Looking at it

```sh
make shot
./bin/shot biome=Alchemy out=shots/alchemy.png                       # as painted
./bin/shot biome=Alchemy ticks=600 out=shots/alchemy600.png          # after ten seconds
./bin/shot x=640 y=-2560 w=128 h=128 scale=2 ticks=240 out=shots/mix.png   # room 2
./bin/shot x=640 y=-2432 w=128 h=128 scale=2 ticks=300 player=1 out=shots/dark.png  # room 6
```

The mix is a thing that flashes, so a still is a still of one tick.
Judge it by a run of them, 30 ticks apart, and by the pool that is
left when they stop.
