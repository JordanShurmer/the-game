# The pot

The wizard carries a little clay pot of black powder. Thrown, it
flies on an arc and breaks on the first thing it touches, and the
break is a small explosion: it scatters matter and gives off a bang
of light. This note says how it flies, how it breaks, what the bang
costs the light, and what this phase leaves out.

`docs/physics.md`, "The blast grades what it meets", says what the
explosion itself does once the pot sets it off. This note is only
about the pot: getting a blast out of the wizard's hand and into the
world.

## The pot is a fixed bag, not a list

`src/pot.odin` holds it. A `Pot` is thirty-two bytes — a position, a
velocity, the light box it last lit, a fuse, a flash counter, and two
flags — and a `Pot_Bag` holds up to `POT_MAX` (8) of them in a fixed
array, the way `Firefly_Swarm` holds its flies. `count` is the high
water mark of slots ever used, not the number currently live: a dead
pot's slot is reused by the next throw before the bag grows, so eight
pots is the ceiling whatever order they land in. Nothing here
allocates.

## Throwing costs a rest, not a resource

`pot_throw` refuses while `rest` is still counting down from the last
throw, or while the bag is already full. Otherwise it sets
`rest = POT_REST` and places a pot at the wizard's hand — his centre,
plus the aim vector times half his body width and a couple more cells,
so it does not start inside him — and sends it off along that aim at
`POT_SPEED`, with `POT_LOB` taken off the vertical component so every
throw arcs rather than flying flat, and his own `vx` carried along so
a throw on the run leads or trails the way a real one would.

There is no ammunition to track and nothing to pick back up. The rest
is the whole cost of throwing, in the way a fixed digger has no charge
to run out: it says how fast the wizard can work, not how much powder
he is carrying.

## The flight is stepped so a fast tick cannot skip a floor

`pot_step` runs the bag once a tick. A pot that is not yet flashing
takes gravity — `POT_GRAVITY` and `POT_MAX_FALL` are the wizard's own,
so a pot falls exactly as he does — counts its fuse down by one, and
then moves.

The move is not one jump to where the velocity says it should land.
At `POT_SPEED` (190 cells a second) a pot crosses more than three
cells a tick, and a single test of the far end would step clean over a
one-cell-thick floor. So it walks the tick's displacement in steps of
at most one cell, testing `player_solid_at` at each one — the same
procedure the wizard's own feet are tested against, so a pot meets the
world exactly as he does. The first solid cell it finds stops it
there; it does not tunnel a cell into the wall it hit.

A pot that never finds a wall still has a limit: `POT_FUSE` (180)
ticks, three seconds. Whichever ends the flight first — a wall or the
fuse — the pot breaks.

## Breaking is one call into the sandbox

A pot's potency is not invented for the pot. It holds `POT_GRAINS`
(4) grains of the same black powder the material table already
carries — `Gunpowder`'s `explosive` field — so

```odin
pot_power :: proc(table: Material_Table) -> u8
```

reads that field, multiplies it by the grain count, and clamps to 255.
The result is both the radius and the power `sandbox_explode` is
called with, which is the same rule `docs/physics.md` gives any other
explosive: the reach is the power, not a fraction of it.

Breaking sets `flash = POT_FLASH` and calls `sandbox_explode` at the
pot's own cell, converted to sandbox coordinates. Two things leave a
pot with no blast at all rather than a wasted one: no sandbox under it
(`t.sandbox == nil`, the case a shot with no play sandbox open would
hit) or a cell that has fallen off the edge of the one that is open.
Either way the pot simply dies; nothing explodes into a world that is
not there to receive it.

## The bang is a light with no body, the way a firefly is

`light_step` and `light_throw` take a `Pot_Bag` exactly as they take a
`Firefly_Swarm`: `light_forget_pots` clears the live box of every pot
that lit one last tick, and `light_throw_pots` floods `l.live` from
every pot that is currently flashing, at `pot_flash_power`, over
`POT_FLASH_REACH` samples, with `POT_FLASH_FALL`. A pot that is only
flying — fuse still burning, no flash yet — throws no light at all; it
is a dark thing in the air until it goes off.

```odin
pot_flash_power :: proc(p: Pot) -> u8
```

shapes `POT_FLASH_POWER` by `(flash / POT_FLASH)` squared: the count
runs down linearly from `POT_FLASH` to zero, but squaring it holds the
brightness near its peak for the first half of the flash and lets it
fall away fast at the end, so the bang snaps bright the instant it
goes off and gutters rather than dimming evenly.

`#assert(POT_FLASH_POWER >= LIGHT_ORB_POWER, ...)` holds a bang to at
least the orb's own brightness — a bang is the brightest thing in the
world while it lasts, the same rule that holds the orb over the trail
he leaves and the trail over the fireflies. It fires at exactly the
orb's power and fades from there, so a bang beside him briefly matches
his own light and then goes dark, rather than out-shining him for the
whole of the flash.

## Looking at it

A flying pot draws as a small dark disc with a warm spark above it for
the fuse; a breaking one draws with `app_draw_glow`, the same
halo-and-core shape the orb and the crystals use, sized by `POT_HALO`
and `POT_BLAZE` and faded by `pot_flash_power`. `shot_draw_pots`
mirrors `shot_draw_fireflies` for the no-window path: it draws only
the flash, because a pot that has not gone off yet has no light to
show a shot.

`Window_Shot` reads `throw=<degrees>` (0 is right, 90 is down, the
same convention `player_aim_of` uses) and `ticks=<n>`: after the
ordinary `walk` argument runs, a shot that asked for a throw holds
`.Throw` for one tick at that aim and then runs `ticks` more ticks of
the sim, so the picture can be taken however long after the throw the
bang needs to be caught in the open.

```sh
make game
xvfb-run -a -s "-screen 0 1280x720x24" ./bin/the-game \
  shot=shots/throw.png walk=-40 throw=20 ticks=10 frames=2
xvfb-run -a -s "-screen 0 1280x720x24" ./bin/the-game \
  shot=shots/bang.png walk=-40 throw=20 ticks=34 frames=2
```

## The numbers

| Constant | Value | What it does |
| --- | --- | --- |
| `POT_MAX` | 8 | pots in the air at once |
| `POT_GRAINS` | 4 | grains of black powder the pot holds |
| `POT_SPEED` | 190.0 | cells per second, along the aim |
| `POT_LOB` | 42.0 | cells per second of lift, so it flies on an arc |
| `POT_REST` | 24 | ticks between throws |
| `POT_FUSE` | 180 | ticks the fuse burns before it goes off in the air |
| `POT_FLASH` | 22 | ticks the bang stays in the light |
| `POT_FLASH_POWER` | 255 | the bang's brightness the instant it goes off |
| `POT_FLASH_REACH` | 34 | samples the flash floods outward |
| `POT_R` | 2 | cells, the pot as it is drawn |

## What this phase leaves out

- **No bounce.** A pot that lands on a shallow slope does not roll or
  skid; it simply meets the first solid cell in its path and breaks
  there, the way a bullet would rather than a thrown object would.
- **No rigid shards.** The clay pot itself is not a body: it is a
  point that draws as a disc, and breaking it never scatters pieces of
  pot, only the matter its blast crumbles.
- **No damage to the wizard.** A pot can be thrown at his own feet and
  the blast will grade the ground under him exactly as it grades any
  other cell, but nothing in this phase reads the blast against his
  own health, because there is no health yet to read it against.
