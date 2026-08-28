# Alchemy

The alchemy of the world, in two parts. The first is a poison, water,
and what the two make of each other. The second is thirteen materials
more: the salts, the metals, and two magics, which is where the world
gets salt out of a pool, black powder out of three minerals, gold out
of quicksilver, and a stone that answers water with light.

This note says what the materials are, what they make of each other,
how the light of it is drawn, and where to walk through it. Everything
here is data. There is no alchemy code: `data/materials.txt` holds the
rows and the sandbox in `docs/physics.md` runs them.

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
a sixth of a second, and it decays to `Air`. It has no `contact`
effect, so it burns nothing. It is light and nothing else.

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
Blast 255 >= Orb_Light 255 > Sparkle 190 > Light_Crystal 110 > Firefly_Light 96
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

The second alchemy added thirteen materials, which takes the shipped
table from 35 to 48. That is still under `SANDBOX_WIDE_IDS` (64), so
the vectorised pass stands and nothing above had to be re-tuned;
`test_the_second_alchemy_leaves_the_wide_pass_standing` is what keeps
it that way, and it fails on the material that would cost the whole
game its fast path rather than on a benchmark somebody has to remember
to read.

Measured on one machine, interleaved, best of three each way. This is
not the machine the numbers above were taken on, so read the pairs and
not the absolute values:

| `bin/bench` | Before the second alchemy | After it |
| --- | --- | --- |
| `Coalmine` 2048, the shipped world | 0.88 ms | 0.91 ms |
| `Gallery` 512, the physics rooms | 0.20 ms | 0.24 ms |
| `Alchemy` 512, this gallery | 0.20 ms | 0.46 ms |

The shipped world and the physics gallery hold their checksums exactly
across the change, which is the number that matters: thirteen materials
no biome uses cost the world nothing, and the two readings that move are
inside the run to run spread of this machine.

The alchemy gallery costs twice what it did because it is doing twice as
much: eight rooms that were empty halls now run matter, three of them
with a reaction on every tick. That is the exhibit, not a regression.

## The second alchemy

Thirteen materials came after the first three, and not one line of code
came with them. Nine are matter a miner would know and four are not,
which is the shape the world wants: the magical has to stand against
something ordinary or it is only colour.

| Material | Old English | What it is |
| --- | --- | --- |
| `Sealt` | *sealt*: salt | A white powder. It goes into water and it comes back out of it |
| `Brine` | — | What salt and water make. It lies between water and `Smylt`, and it carries a current far better than either |
| `Nitre` | — | Saltpetre off a cave wall. No fuel at all: what makes another fuel burn faster than it can alone |
| `Brimstone` | *brynstan*: the burning stone | Sulphur. It does not catch as flame; it gives off its reek first, and the reek burns |
| `Reek` | — | The choking yellow fume brimstone gives off. It rises, it poisons, and a flame walks up it |
| `Sweartsealt` | *sweart*: black | The black salt nitre and brimstone make. Half of black powder, wanting the other half |
| `Leag` | *leag*: lye | Wood ash left standing in water. The other end of the scale from acid |
| `Cwicseolfor` | *cwicseolfor*: quicksilver | A liquid metal at 13.5, the heaviest thing that flows here |
| `Gemang` | *gemang*: a mingling | The soft solid quicksilver takes gold up into |
| `Galdor` | *galdor*: an incantation | A spell in a bottle. Every row it is in spends it as a flash |
| `Leoma` | *leoma*: a gleam, a ray of light | Rock that has taken a spell. No light of its own; it answers water with one |
| `Haelu` | *haelu*: health, healing | The cure, and the quiet opposite of the mix |
| `Sceadu` | *sceadu*: a shadow | A heavy black liquid that puts fires out and blinds a gleam to dead glass |

Every one of them is a row in `data/materials.txt` and a row or two in
`[Reactions]`, and `src/alchemy_test.odin` measures each one in the
sandbox: paint the cells, step the tick, count what is left.

### The salt road

```
Sealt + Water -> Brine + Brine   120
Sealt + Ice   -> Brine + Water    60
Brine + Fire  -> Steam + Sealt   128   # the flame is smothered by the salt it leaves
Brine + Fire  -> Sealt + Fire    127   # or the brine dries where it stands and the flame burns on
Brine + Lava  -> Steam + Lava     40
Brine + Lava  -> Sealt + Lava    120
```

A road that runs both ways. Salt goes into water and heat takes it back
out, and neither end of it is a dead end: what comes out is what went
in, and the pool between them is a material of its own that the world
did not have. `test_salt_goes_into_water_and_heat_brings_it_back`
walks it in both directions in one sandbox — 168 cells of salt into 168
of water leaves 262 of brine, and a flame banded into that brine brings
the salt back.

Boiling is two chains rather than two rows, because a reaction leaves
two cells and there are three things to say: the water goes off, the
salt stays, and where the salt stays is not always where the flame was.
Half the rolls smother the flame with the salt it made; half dry the
brine where it stands and leave the flame burning.

**A salt pan crusts over.** `Sealt` at 2.1 is heavier than brine at
1.03 and lighter than lava at 2.4, so the salt a pan of brine leaves
settles exactly between the two and caps the pan. This is the trap of
"Layering seals a slow drip" again, and now it is a powder doing it:
80 cells of brine over lava leave 10 of salt in the first few hundred
ticks and then stand for ever, brine still under the crust, lava still
under that. `test_a_salt_pan_crusts_over_with_its_own_salt` runs it
5000 ticks and requires the counts to be identical at 1000 and at 5000.

Room 7 of the gallery is both halves: the road on the left, the crust
on the right.

### Black powder, in two steps

```
Nitre       + Brimstone -> Sweartsealt + Sweartsealt   60
Sweartsealt + Coal      -> Gunpowder   + Gunpowder     90
```

Black powder was found before this and it is made now. A reaction takes
two cells and black powder is made of three things, so it cannot be one
row: nitre and brimstone make the black salt where they touch, and the
black salt takes up coal and is powder.

This is the pattern to copy for anything that needs three ingredients.
It costs one material — the half made thing — and it buys a recipe the
player can find by dropping one pile onto another.
`test_black_powder_is_made_in_two_steps` holds both steps.

Brimstone burns the same way, in two steps, for the same reason:

```
[Brimstone]  flammability = 6   burns_to = Reek
Reek + Fire -> Fire + Fire   200
Nitre + Fire -> Fire + Fire  200
```

A flame reaching brimstone does not get a flame back. It gets the fume,
and the fume is the fuel, so a bed of brimstone burns through a yellow
cloud that rises off it and poisons what it touches on the way.
`test_brimstone_burns_by_way_of_its_reek` lights one end of a bed and
requires the reek before anything else. Nitre is no fuel at all and
still feeds a fire, which is what an oxidiser is.

### Lye, and the acid it answers

```
Ash  + Water -> Leag  + Leag     35
Leag + Acid  -> Smylt + Smylt   200
```

Ash left standing in water is lye, so lye turns up wherever something
burnt has fallen in a pool and nobody has to pour it. Lye and acid put
each other out and leave `Smylt`, which is the second road to the calm
liquid and the first that has nothing to do with poison.

Nothing seals this one. `Smylt` at 1.05 is lighter than lye at 1.1 and
lighter than acid at 1.2, so what the reaction leaves floats up out of
the front instead of settling across it, and acid still arriving sinks
straight through the lye to what has not reacted yet. A room that drips
acid onto lye runs until one of them is gone, and room 9 is that room.

### The metals

```
Cwicseolfor + Gold -> Gemang + Gemang   150
Gemang      + Fire -> Gold   + Fire      40
```

Gold is a solid, and a solid does not flow: it stays in the wall until
something breaks it, and until now breaking it was the only way to move
it at all. Quicksilver takes it up instead, into an amalgam along the
line where the two meet, and fire drives the quicksilver back off and
leaves the gold standing wherever the flame reached.

The flame has to stand on the amalgam to do it, and a flame in the air
rises away, so the way to work an amalgam is a film of oil on top of it
and a light. `test_fire_drives_the_quicksilver_off_and_leaves_the_gold`
does exactly that, because the first cut of it lit nothing at all:
`sandbox_ignite` only ignites what is flammable, and an amalgam is not.

A blast breaks an amalgam back into quicksilver: `crumbles_to =
Cwicseolfor`, so what a pot leaves in a gilded wall is a puddle.

### The two magics

```
Galdor + Cwicseolfor -> Sparkle + Gold        60
Galdor + Rock        -> Sparkle + Leoma       12
Leoma  + Water       -> Leoma   + Sparkle     40
Haelu  + Attor       -> Smylt   + Smylt      255
Haelu  + Ash         -> Dirt    + Dirt        60
Sceadu + Fire        -> Sceadu  + Smoke      220
Sceadu + Leoma       -> Sceadu  + Obsidian    30
Sceadu + Haelu       -> Smylt   + Smylt      255
```

**A spell is spent in the flash it makes.** Every row `Galdor` is in
writes the `Sparkle` into the cell that held the spell, never into the
cell it worked on, so the eye always reads the flash as the spell going
out. Quicksilver under a spell is gold and plain rock under one is a
gleam, and there is a spark either way and one less cell of spell.

**A gleam is not a light.** `Leoma` has `luminosity = 0`, which is the
whole of it: it answers water with a spark and it is never used up
doing so. A vein of it under a drip flickers for as long as the drip
lasts, and the drip is what runs out.
`test_a_gleam_answers_every_drop_with_a_spark` holds all three parts —
the spark, the crystal that stays, and the water that goes.

This is the honest way to make a glowing material without new code. The
world draws light from the rings in `docs/lighting.md` and nothing
else, so a material that carries a `luminosity` no ring ever reads
would be a number that lies. A material that *makes* `Sparkle` lights
the room through the ring that is already there.

**A magic only skins what it lies on.** `Galdor` turns rock into gleam
and there is no row for `Galdor` on gleam, so the first cell it changes
is a shell over the rest and the spell can go no deeper. `Sceadu` does
the same to a slab of gleam: 1152 cells of it under a whole tank of
shadow give up 58 to obsidian and then stand. Nothing had to be written
to stop a bottle of spell turning a whole cave to crystal — the shape
of the reaction stops it, the way `Smylt` stops the mix in "Layering
seals a slow drip". A pour that has to reach further has to be given
somewhere for the shell to fall away to.

**The cure is the quiet opposite of the mix.** `Attor` and water flash
and leave `Smylt`; `Attor` and `Haelu` leave the same `Smylt` and throw
no light at all. `test_the_cure_puts_the_poison_out_with_no_light`
requires the spark ring to stay empty for 2000 ticks, which is the only
way to test a thing that is meant not to happen.

**The shadow is the opposite of the light.** It puts fires out and is
not spent doing it, it blinds a gleam back to dead black glass, and it
and the cure undo each other into `Smylt`, so the two magics cancel the
way an acid and a base do.

The world has nothing to heal yet. The day the wizard can be hurt,
healing becomes rows in the reaction table, the way every other
effect of the world already is.

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
Moving that code must not move a pixel: `data/rooms/gallery_0.png` is
regenerated and has to come back byte for byte the same file.

Rooms 1 to 6 are the first alchemy and rooms 7 to 14 are the second.
Room 10 and rooms 15 and 16 are halls with plinths, walled and doored
and empty, because this gallery is meant to be filled as the alchemy
grows, and it has been once already.

Room 10 is empty for a reason of its own: room 6 comes down into it,
and room 6 is judged by what can be seen from it, so nothing in room 10
may make a light. Rooms 15 and 16 are the ones left for what comes
next.

| # | Room | What it shows | What starts it |
| --- | --- | --- | --- |
| 1 | Attor | A tank of poison pours down a stair into a basin. No water, no light: this is the liquid on its own | gravity |
| 2 | The mix | A rack of alternating Attor and water pipettes rains the two down side by side into one basin. Sparks the width of the room, for about 370 ticks | gravity |
| 3 | The measure | Three parts Attor sealed over three parts water in a graduated tube, against a bedrock scale. What is left stands at four | gravity |
| 4 | The rain, and the seal | Water rains onto a flat pool of Attor. It sparks the width of the pool for about a hundred ticks, and is then still for ever. The trap the other rooms are built to answer | gravity |
| 5 | Layers | Oil, water, Smylt and Attor pour into one tank and settle in four bands, in the order the densities say | gravity |
| 6 | The dark | Two ducts a cell apart drop Attor and water down a black room as neighbouring columns. A ribbon of sparks and nothing else, for about 1400 ticks | gravity |
| 7 | The salt road | A hopper of salt over a basin of water on the left, and a tank of brine over a pan of lava on the right. Salt in, salt out, and the crust the pan caps itself with | gravity |
| 8 | Black powder | Two tubs of banded nitre and brimstone, each draining onto a walled bed of coal. The black salt is made in the tub and the powder on the bed. Nothing here is lit: the fire is the visitor's to bring | gravity |
| 9 | Lye | Hoppers of ash and acid over one basin of water. The ash makes lye and the acid answers it, and nothing it makes can seal it, so it runs until one of the two is gone | gravity |
| 10 | Hall | Empty, and unlit on purpose: room 6 comes down into it | — |
| 11 | The quicksilver | A pan floored with gold under a tank of quicksilver. An amalgam forms along the line where the two meet, and gold moves for the first time | gravity |
| 12 | The gleam | A pipette of Galdor onto plain rock on the left, and a pipette of water onto a vein of gleam on the right, 384 cells and about 380 ticks each. A spell spends itself in a flash and skins the stone it lands on; a gleam answers every drop with a spark and is never used up | gravity |
| 13 | The cure | Two ducts a cell apart drop Attor and Haelu down a dark room, the way room 6 drops Attor and water. The same calm liquid, and no light at all. This is room 6 with the light taken out of it, and that is the exhibit | gravity |
| 14 | The shadow | A slab of gleam under a tank of Sceadu. What the shadow lies on is blinded, gleam to dead black glass, and no deeper: the blinded shell is what stops it | gravity |
| 15-16 | Halls | Empty, walled, doored, with a plinth. Room for what comes next | — |

Room 6 is the room the first half of this note is for. Shoot it with
the lighting on and nothing else in the frame: a ribbon of sparks hangs
down the middle of a black room, and the light of it reaches the two
chambers that feed it and nothing further.

Room 13 is the same shot with nothing in it, and it has to be looked at
next to room 6 or it says nothing: two liquids fall side by side the
whole depth of a black room, they leave the same `Smylt` room 6 leaves,
and the frame stays black.

## Looking at it

```sh
make shot
./bin/shot biome=Alchemy out=shots/alchemy.png                       # as painted
./bin/shot biome=Alchemy ticks=600 out=shots/alchemy600.png          # after ten seconds
./bin/shot x=640 y=-2560 w=128 h=128 scale=2 ticks=240 light=1 out=shots/mix.png   # room 2
./bin/shot x=640 y=-2432 w=128 h=128 scale=2 ticks=100 light=1 out=shots/dark.png  # room 6
./bin/shot x=896 y=-2432 w=128 h=128 scale=3 ticks=1200 out=shots/powder.png       # room 8
./bin/shot x=896 y=-2304 w=128 h=128 scale=3 ticks=200 light=1 out=shots/gleam.png # room 12
./bin/shot x=512 y=-2176 w=128 h=128 scale=3 ticks=200 light=1 out=shots/cure.png  # room 13
```

A room of the second alchemy sits at world x `512 + 128 * col`, y
`-2560 + 128 * row`, counting rooms 1 to 16 in reading order. Rooms 8,
9, 11 and 14 make no light of their own, so shoot them flat: the
picture to read there is what the colours have become, not what is lit.

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
