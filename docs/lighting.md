# The lighting

The world is dark. The light in it comes off the orb on the wizard's
staff, off the crystals of light that fall out of that orb as he walks
and hang in the air where they fell, and off the fireflies that drift
over a pond. So the picture a player reads is a warm pool around
himself, a thread of small lights behind him marking every place he has
been, a cold green shimmer over the water, and gloom everywhere else.

This note says how that is built, what it costs, and the three rules
that are easy to break and only visible in a shot.

## What the codebase decides for us

1. **`Sim` holds the game and knows nothing of a screen.** The light is
   a field of `Sim`, next to the sandbox, and both draw paths read it.
   `light_shade` turns a material colour and a light level into the
   colour to write, and that is the only place the look lives.
2. **A picture is the check.** `bin/shot` draws the light through the
   same procedures the window draws through. `player=1` turns it on and
   `light=0` turns it off, so any change can be judged from a terminal.
3. **The sandbox already forgets.** Leave the 2048 cell square and the
   sandbox is re-opened on the new one, taking the digging with it. The
   light follows exactly that rule rather than inventing a second one.

## Two lights, one grid

Both lights write into a grid of light samples, one sample per
`LIGHT_CELL` (4) cells, covering the same 2048 cell square the play
sandbox covers. There are two such grids:

| Grid | Holds | Cleared |
| --- | --- | --- |
| `stat` | what the crystals left behind | only when he leaves the square |
| `live` | what the orb and the fireflies throw this tick | every tick, over the boxes they wrote |

A cell reads the brighter of the two, interpolated between the four
samples around it, so a light level is smooth across a wall that a
sample grid is far too coarse to describe.

Splitting them is the whole reason the trail is free. The orb moves, so
its light is thrown away and re-thrown 60 times a second, and so does a
firefly. A crystal never moves, so its light is flooded **once**, at
the tick it falls, and after that it costs nothing at all to keep a
place lit for the rest of the game.

Everything that moves is cleared before anything is thrown.
`light_throw` erases the box of the orb and the box of every firefly
that was lit last tick, and only then floods them all again. Clearing
one source after throwing another would rub out light that had just
been written.

## Light goes round corners, not through walls

A flood fills the grid outward from the source, one sample to its eight
neighbours, multiplying by a fixed fraction at every step. The fraction
depends on the sample it leaves:

| Leaving | Straight | Diagonal |
| --- | --- | --- |
| open air | 212/256 | 196/256 |
| anything solid | 108/256 | 75/256 |

Solid is whatever stops the wizard: **what blocks him blocks his
light.** `light_dense_at` asks `player_solid_at` about the middle cell
of the sample, so there is one answer to what is solid and not two that
can drift apart.

That single asymmetry is what makes the picture read as caves. Light
runs a long way down an open passage and dies within a few samples of
entering rock, so a wall catches the light on the face turned toward
the orb and holds the dark behind it, and a corridor around a corner
lights up while the rock between does not.

The flood is a queue, not a recursion, and a sample is pushed only when
the light reaching it is brighter than the light already there. It
stops at `LIGHT_FAINT`, and it is bounded to a box of `reach` samples
around the source. **The box must outlast the falloff.** A box that
stops while the light is still bright draws a square of light instead
of a pool; `test_every_reach_outlasts_the_falloff_it_bounds` runs the
falloff out and fails if either reach is short.

## The gloom is a colour, not an absence

`light_shade` takes the material's own colour and a light level and
does three things in order.

1. **The gloom.** With no light on it a cell keeps about an eighth of
   its red, an eighth of its green and a sixth of its blue, plus a
   small lift. Rock a long way from the orb is a dark shape that can
   still be read, not a black hole. The blue survives the dark hardest,
   which is what makes an unlit cave read as night rather than as a
   picture with the brightness turned down.
2. **The haze.** Light is added back into whatever the material lacks,
   warm and strongest where the cell is darkest. Air is nearly black,
   so lit air glows and unlit air does not, and that is what makes the
   light look like it fills a space instead of merely painting the
   walls of one.
3. **The bloom.** Past `LIGHT_BLOOM_KNEE` the colour is pulled toward
   the light's own, so the cells nearest the orb are bleached almost
   white.

Between the gloom and the material's colour the mix runs on
`light_response`, not on the light level itself. The flood falls off
by a fixed fraction per step, which is exponential, and mixing on that
directly puts everything past about thirty cells into the dark at once.
The response is the level raised to `LIGHT_RESPONSE_GAMMA` (0.65),
built once into a 256 byte table, and it is what turns a steep falloff
into a broad readable gradient with a bright heart.

## The crystals

One crystal falls out of the orb every `LIGHT_DROP_STRIDE` (21) cells
of travel, and hangs exactly where it fell.

**A crystal has no physics and no interactions.** It does not fall to
the floor, it does not collide, nothing in the sandbox can touch it and
it can touch nothing. It is a position, a light that was flooded once,
and a seed that keeps the twinkle of one out of step with the next. The
whole of `Crystal` is twelve bytes.

They are kept in a ring of `LIGHT_CRYSTALS` (1024). When it wraps, the
oldest crystal stops being drawn — but its light was flooded into
`stat` and stays there, so the place it lit stays lit. The light soaks
into a place; the crystal is only the thing you can see it coming from.

**The trail never outshines the orb.** `LIGHT_CRYSTAL_POWER` is 168
against the orb's 255, held by a `#assert` and by
`test_the_trail_he_leaves_never_outshines_the_orb_he_carries`. Break
that and every place he has been is as bright as the place he is, and
the picture stops saying which is which.

## The fireflies

A firefly is a light with no body: a home over the water, two sine
waves that carry it away from that home and back, a pulse that makes it
blink, and nothing else. `src/firefly.odin` holds the whole of it in 36
bytes, and `firefly_gather` puts `FIREFLY_PER_POND` (7) of them over
every pond the world digs, spread across its mouth and hanging
`FIREFLY_HOVER` cells above the water.

They drift on the swarm's own clock, which advances one tick at a time,
so the same ticks always put them in the same places and a replay of
the same commands gives the same picture.
`test_the_swarm_moves_the_same_way_every_time` holds that.

**A firefly throws its light and takes it with it.** It floods into
`live` like the orb, at `FIREFLY_POWER` (96) scaled by its blink, over
a reach of 8 samples, and it leaves nothing behind: walk the swarm away
and the water goes dark again. That is the difference between a firefly
and a crystal, and `test_a_firefly_leaves_no_light_behind_it` is the
line between them.

The order of the three lights is a rule as well: **96 against the
crystals' 168 against the orb's 255**, held by a `#assert`. A pond that
outshone the trail would tell the player the wrong thing about where he
has been.

`docs/water.md` says what the pond is that they gather over.

## The orb is where the art says it is

`tools/seed_wizard.py` draws the orb at (17.5, 5) in a 24 x 32 frame,
and `sprite_frame_origin` lays that frame down at
`(floor(x) - 12, floor(y) - 24)`. So the light leaves his staff at
`LIGHT_ORB_DX` (6) cells to his facing side and `LIGHT_ORB_DY` (19)
cells above his feet, mirrored about the middle column of the frame,
which is half a cell left of the point the player struct holds.

Those are two numbers in two files that must agree, exactly like the
body box.  `test_the_orb_light_starts_where_the_sheet_draws_the_orb`
reads the shipped sheet at the point the constants compute, for both
facings, and fails unless it lands on the orb the seeder drew. The
light's colour and the orb's paint are the same two colours for the
same reason.

**A buried orb still gives light.** His staff head rides six cells
above his hat, so in a passage he cut himself the orb can sit inside
rock, and a light thrown from inside rock dies at once.
`light_orb_source` walks from the orb toward his chest and throws from
the first open cell it finds, so the light comes off the staff wherever
the staff can be seen and off his shoulder where it cannot.

## What it costs

Measured on the shipped world: **67 microseconds a tick**, against 1.39
milliseconds for a sandbox tick of the same square. Almost all of it is
the one orb flood, about 2500 samples of queue. Seven fireflies add
about 11 microseconds a tick while he stands beside their pond, and
nothing at all once they fall outside the grid. A crystal costs one
smaller flood, once, and nothing afterwards. Drawing costs a table
lookup and about fifteen integer operations per texel, which at the
zoom the game opens at is 320 x 180 of them.

The two grids and the queue are 768 KB together, allocated once per
`Sim`.

## What this phase leaves out

- **No shadows with edges.** Light is attenuated by what it passes
  through, not traced, so a wall darkens the light behind it rather
  than cutting a hard silhouette out of it.
- **Nothing else in the world emits.** Lava, fire and burning oil are
  drawn at their own colours and light nothing around them. They are
  the obvious next sources, and they need no new machinery: a flood
  into `live` at their position is all a light is here, which is all a
  firefly is.
- **The fireflies do not know the world.** They drift through the air
  over their pond on a fixed path, and rock in the way neither turns
  them nor stops them. Nothing can catch one, and one can catch
  nothing.
- **The light does not survive the square.** Walk 2048 cells and the
  crystals behind you are forgotten along with the digging, because
  they live in the same square the sandbox does.
- **The editor is unlit.** `TAB` and the tile editor draw the world
  flat, because terrain is authored by looking at it and gloom is not
  the thing being judged there.
