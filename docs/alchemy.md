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

### Layering seals a slow drip

`Smylt` sits between the two reagents on purpose: at 1.05 it is
heavier than `Water` (1.0) and lighter than `Attor` (1.25), so a pool
of the three settles into three clean bands, water on top, `Smylt` in
the middle, `Attor` on the bottom. That is what "The two liquids"
above is for, and it is also a trap for any room that drips water onto
a flat, deep pool of `Attor`: the first drop reacts and leaves a film
of `Smylt` exactly where it landed, and that film is denser than the
water still arriving and lighter than the `Attor` still underneath, so
it stays put. The drop point is sealed, floor to ceiling, on the very
first drop, and no reaction below the surface ever happens again no
matter how much water is still falling.

This is measured, not guessed. A reservoir over a flat pool, however
big the reservoir, reacts for a few tens of ticks and then goes still:
every design tried this way (a single hole, several staggered holes
over the same flat pool, a staircase of ledges coated in `Attor`) shows
the same shape, a short burst ending under 250 ticks in from a cold
start, and then nothing, for as long as the room is left running.
Widening the hole, deepening the reservoir, and adding more of them all
change how much reacts in the burst; none of them make the burst last
longer, because the seal does not care how much water is still coming.

The fix is not a bigger reservoir, and it is not a slope either. A
slope helps a little, because `Smylt` formed on one slides away from
the drop point instead of capping it, but it only puts the seal off:
the slope silts up with its own product from the bottom, and the room
goes quiet again. The fix is to give the two liquids nowhere to
settle. **They must meet in the air and nowhere else.** Room 2 rains
`Attor` and water down side by side into one basin, and room 6 drops
them as two neighbouring columns the whole depth of a dark room.
Neither reaction ever stands on anything: what a drop leaves behind
falls away from the front instead of over it, and the room runs for as
long as the taps have anything in them.

Room 4 is left as a flat pool under rain on purpose, so the museum
shows the trap as well as the answer to it. It sparks the width of its
pool for about a hundred ticks and is then still for ever, with a pool
of poison and a rain of water that can no longer reach each other.

### A tap is a pipette, not a pond

How long an exhibit runs is a number chosen when it is drawn:

    ticks it runs = cells in the tap / cells across its hole

A hole one cell wide passes at most one cell a tick, because one cell
is all that fits through it in a step. That is the whole meter, and it
is why room 2's rack of pipettes runs for about 370 ticks and room 6's
two chambers for about 1400 each.

The shape of the tap matters as much as the size of the hole. A wide
tank over a narrow hole does **not** drain at one cell a tick: a
liquid only moves sideways into a cell that has nothing claiming the
cell above it, so a full tank cannot walk its bottom row across to the
hole, and it drains at the speed its surface can spread instead —
slower, and slower still the wider it is. A tall narrow column over
its own hole has every cell standing over the hole already. So a tap
that has to keep time is a pipette; a tank that only has to look full
is a pond.

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

Three new materials pushed the shipped table to 35, past
`SANDBOX_WIDE_IDS` (32), and the first cut of this note shipped that
plainly: the vpshufb fast path `docs/physics.md` "LOAD is now wide"
describes stood down for the whole game, on every biome, whether or
not any alchemy was near, and `Coalmine` alone read 1.09 ms a tick
before against 1.15 after. That is not an acceptable price for three
rows of data, so `SANDBOX_WIDE_IDS` is 64 now, not 32. The scheme
generalises the way the old one worked: it was two 16-entry shuffle
tables and one `vpcmpgtb`/`vpblendvb` on `idx > 15`, covering ids 0..31
a byte half at a time. It is four tables and a chain of three blends
now, on `idx > 15`, `idx > 31` and `idx > 47`, covering ids 0..63; every
id still stays under 128, so the signed compares still read right.
`weight_lut` grew from `4 * SANDBOX_WIDE_LANES` bytes to `8 *
SANDBOX_WIDE_LANES`, one quarter per table, and `sandbox_build_luts`
fills all four. The asm itself had to be re-tuned to fit: the naive
translation needs 19 live ymm registers for 16 that exist, so `sel`
and the final unpack step now share one register across the whole
block instead of each getting its own, which is the only reason the
four-table version compiles at all.

Measured on the shipped map, `bin/bench`'s default run (`Coalmine`,
2048 square, 100 ticks, interleaved with the build before this rung,
best of five each way):

| | Before this rung | After it |
| --- | --- | --- |
| ms a tick | 1.09 | 1.09 |

Widening the lookup gets back to the number `docs/physics.md` reports
for its own build, and the checksum never moves either side of it.
`test_the_weight_lut_holds_every_material` and
`test_the_wide_weights_agree_with_the_plain_ones` once again require
the shipped table to fit the lookup, rather than accepting that it
does not; `test_a_long_material_table_stands_the_wide_pass_down` still
holds the stand-down correct for a table that truly does outgrow 64,
because that behaviour is worth keeping even though the shipped table
no longer needs it.

The alchemy gallery itself, `bin/bench biome=Alchemy size=512
ticks=900`, costs 0.13 ms a tick against the physics gallery's 0.30 at
the same size: the alchemy rooms are quieter, not more expensive.

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
| 2 | The mix | A rack of alternating Attor and water pipettes rains the two down side by side into one basin. Sparks the width of the room, for about 370 ticks | gravity |
| 3 | The measure | Three parts Attor sealed over three parts water in a graduated tube, against a bedrock scale. What is left stands at four | gravity |
| 4 | The rain, and the seal | Water rains onto a flat pool of Attor. It sparks the width of the pool for about a hundred ticks, and is then still for ever. The trap the other rooms are built to answer | gravity |
| 5 | Layers | Oil, water, Smylt and Attor pour into one tank and settle in four bands, in the order the densities say | gravity |
| 6 | The dark | Two ducts a cell apart drop Attor and water down a black room as neighbouring columns. A ribbon of sparks and nothing else, for about 1400 ticks | gravity |
| 7-16 | Halls | Empty, walled, doored, with a plinth. Room for what comes next | — |

Room 6 is the room this whole note is for. Shoot it with the lighting
on and nothing else in the frame: a ribbon of sparks hangs down the
middle of a black room, and the light of it reaches the two chambers
that feed it and nothing further.

## Looking at it

```sh
make shot
./bin/shot biome=Alchemy out=shots/alchemy.png                       # as painted
./bin/shot biome=Alchemy ticks=600 out=shots/alchemy600.png          # after ten seconds
./bin/shot x=640 y=-2560 w=128 h=128 scale=2 ticks=240 light=1 out=shots/mix.png   # room 2
./bin/shot x=640 y=-2432 w=128 h=128 scale=2 ticks=100 light=1 out=shots/dark.png  # room 6
```

Rooms 2 and 6 are lit by nothing but their own reaction, so there is no
wizard to carry the light: `light=1` with no `player` follows the
middle of the view instead of the origin, which is the only way a room
this far from where he starts can be judged lit at all. `player=1`
would light the shot from wherever he starts instead, nowhere near
this gallery, and the room would read as dark for the wrong reason.

The mix is a thing that flashes, so a still is a still of one tick.
Judge it by a run of them, 30 ticks apart, and by the pool that is
left when they stop. Room 6's burst is brief, measured at "Layering
seals a slow drip" above: look inside the first 150 ticks or the shot
misses it.
