# The drudge

The first bad guy. He was a miner once, and the coal took the rest of
him: he walks the same stretch of tunnel he has always walked, back
and forth, because a man can forget almost everything and still not
forget the walk to the seam and back. He does not chase. He does not
give up the walk for anything, even you. But if he sees you, he faces
you, and every four seconds or so he lobs a pot of black powder in
your direction — not to be fair, just to be rid of you. This note says
how he is built, the numbers he moves by, and what this phase leaves
out.

## He is a fixed bag, like the pots he throws

`src/drudge.odin` holds him. A `Drudge` is twenty bytes — a position,
a fall speed, how far he has walked this leg, which way he is walking,
whether he is on the ground, how many ticks he still remembers seeing
you, and how many ticks until he may throw again — and a `Drudge_Bag`
holds up to `DRUDGE_MAX` (4) of them in a fixed array, the same shape
`Pot_Bag` and `Firefly_Swarm` use. Only one is placed this phase; the
rest of the room is there because a second and third drudge cost
nothing to add later and nothing to leave empty now.

Nothing here allocates, and nothing here is a general "enemy system."
One struct, one bag, one step procedure. When a second kind of bad guy
arrives it gets its own file and its own bag, the way the pot and the
fireflies each have theirs, not a shared base class neither of them
asked for.

## He throws the same pot, off his own bag

The drudge does not carry a new weapon. He throws the very `Pot`
`src/pot.odin` already defines, flown by the very `pot_step` that
already flies the wizard's own, so a pot in the air behaves exactly
the same whoever threw it: it falls, it lights its own fuse, it walks
its flight one cell at a time so a fast tick cannot skip a floor, and
it breaks into the same call to `sandbox_explode` either way.

What he does not share is the *bag*. `Sim` now holds `pots` (the
wizard's) and `drudge_pots` (every drudge's) as two separate
`Pot_Bag`s. `Pot_Bag.rest` is a single counter, and the wizard and a
drudge cool down on entirely different clocks — the wizard's `POT_REST`
is two thirds of a second so a hand feels responsive, a drudge's is
four seconds so a throw feels like an event and not a hailstorm. One
shared bag would mean a drudge throwing could stop the wizard's own
throw from cooling down, or the other way round, for no reason a
player could ever read on screen. Two small bags is cheaper than
explaining that coupling away, and `pot_step` does not care which bag
it is handed: it is already written against `^Pot_Bag` and nothing
about it names the wizard.

The one place that *did* name the wizard is `pot_throw`, which takes a
whole `Player` to get at his position, his aim and his own `vx`. A
drudge is not a `Player`. So the slot-finding and the placing of a
`Pot` into a bag — the part with no wizard in it at all — is now its
own small procedure, `pot_launch(bag: ^Pot_Bag, x, y, vx, vy: f32) ->
bool`. `pot_throw` computes the wizard's hand position and his aimed
velocity and calls it; `drudge_throw` computes a drudge's own hand
position and a gentler velocity and calls the same thing. Nothing about
`pot_launch` or `pot_step` changed to make this possible — the split
only pulled twelve lines out of `pot_throw` that never touched a wizard
in the first place.

## Patrol: back and forth, kept honest by three rules

A drudge starts walking one way and keeps walking that way at
`DRUDGE_WALK_SPEED` (22 cells a second, a plod against the wizard's own
42) until one of three things turns him around:

1. **A wall.** The cell at his leading edge is solid.
2. **A ledge.** The ground he is walking on runs out — the cell one
   step ahead of his leading edge, at his own foot row and the row
   below it, is open on both. He turns rather than walks off into the
   dark, because "somewhat back and forth" was never meant to include
   a fall down a shaft he cannot climb back out of.
3. **A leash.** He has walked `DRUDGE_PATROL_LEG` (60) cells since his
   last turn, wall or no wall. Left alone in a long straight drift he
   would otherwise walk to the edge of the world; the leash is what
   keeps "back and forth" true even in a tunnel that never narrows.

Turning costs nothing but his direction: `walked` resets to zero and he
starts counting the other way. There is no acceleration and no
friction, unlike the wizard — he either walks at `DRUDGE_WALK_SPEED` or
he does not walk, because a shuffling patrol reads as alive and a
smoothly eased one reads as a camera move.

**Vertical movement is gravity only.** He falls exactly as a pot does
— `PLAYER_GRAVITY` and `PLAYER_MAX_FALL`, the wizard's own numbers,
walked down one cell at a time so a fast tick cannot skip a floor he
should have landed on. He does not jump, and he does not climb the
three-cell lip the wizard climbs without breaking stride: a lip he
cannot walk over reads, correctly, as a wall, and he turns at it. That
is a deliberate loss of one of the wizard's abilities, not an
oversight — a patrol that can climb is a patrol that can eventually
climb into the room the player is hiding in, and the whole point of
this phase is that he cannot.

**Patrol never stops, whatever he sees.** The owner's rule is exact:
*he does not chase.* So the patrol rules above run every tick,
whether or not he has seen the player, and nothing below changes his
direction or his speed. Seeing the player changes only which way he
*faces* and whether he *throws* — never where his feet are going.

## Sight: seeing him, not just standing near him

A drudge sees the player when all three hold:

1. **Range.** The player is within `DRUDGE_SIGHT_RANGE` (140 cells) of
   him, dead centre to dead centre.
2. **The half he is walking toward.** The player is on the side of him
   his current patrol direction faces — not behind him. A drudge does
   not have eyes in the back of his head, and giving him a narrower
   cone than "the whole side he is walking toward" would only make him
   feel like he was looking through a keyhole for no gain in the
   fiction.
3. **A clear line to him.** Nothing solid stands between the two
   centre points.

The third rule is the one the whole phase leans on: **line of sight is
checked against terrain**, so standing behind a wall of rock — or
behind a wall the wizard's own digger just cut — genuinely hides the
player. `docs/pot.md` already walks a line one cell at a time, testing
`player_solid_at` at each step, to fly a pot through the world without
tunnelling through a thin floor; sight uses the same technique, pulled
out as `terrain_line_clear`, a small procedure beside `player_solid_at`
that answers one question — is the straight line between these two
points ever blocked — rather than moving anything along it. The
plasma digger's beam (`sandbox_cut`) was the other candidate and it is
not this job: it asks what a beam can *carve*, graded by hardness
against a digging power, and a wall a drudge cannot see through is
still a wall a strong digger could eventually cut. Sight needed the
plainer question `player_solid_at` already answers — does anything
here stop a body — the same question the pot's own flight already
asks.

**Seeing him is remembered for `DRUDGE_ALERT_HOLD` (30 ticks, half a
second) after the line breaks.** Without that, ducking half a step
behind a corner and back would flicker him in and out of "sees you"
every tick the geometry is exactly on the edge, which reads as
twitchy rather than watchful. With it, slipping fully behind cover for
longer than half a second genuinely loses him — this is the sneaking
the phase is about — and he goes back to facing his patrol direction
and stops throwing. He never once moves toward where he last saw the
player; losing sight costs him nothing but the aim.

## Throwing: gentler than the wizard's own hand

Once he sees the player, he throws no faster than every
`DRUDGE_THROW_INTERVAL` (240 ticks, 4 seconds), aimed at the player's
centre at the moment of the throw. It does not lead him: a drudge
throws where the player *is*, not where he is *going to be*, so a
player who is moving is already most of the way to dodging a throw
before it leaves the drudge's hand, and reading that off the screen —
"it aims at me, not ahead of me, so if I'm already moving I'm mostly
clear" — is the whole of the skill this phase asks for.

"Gently" is two numbers softer than the wizard's own throw:
`DRUDGE_THROW_SPEED` (110 cells a second, against `POT_SPEED`'s 190)
and `DRUDGE_THROW_LOB` (70 cells a second of lift, against `POT_LOB`'s
42). A slower pot on a higher arc takes longer to arrive and is easier
to watch coming than the wizard's own flat, fast throw — which is
right, because the wizard's throw is a tool he aims with intent and
the drudge's is a threat the player is meant to have time to read and
step out from under.

Both numbers feed the same `pot_launch` the wizard's own throw calls,
into the drudge's own `drudge_pots` bag, so the pot that lands is
identical in every way but where it started and how it flew to get
there.

## He is not hurt by his own blast, not yet

A pot he throws grades the ground and anything the sandbox holds
exactly as any other pot's blast does. It does not grade *him* — there
is no health on `Drudge`, and nothing here reads a blast against one.
That is not an oversight either: `docs/player.md` says the wizard has
no health yet, and giving the one enemy in the game a health bar
before the one player has one would be building the second half of a
fight this phase was explicitly asked not to build. A death this small
— clear a flag, stop drawing him — would be cheap to add, but there is
nothing yet that would ever set the flag, and a field nothing writes
is worse than no field.

## Looking at him

He draws as two stacked rectangles in `DRUDGE_BODY` and
`DRUDGE_BODY_DARK` — a plain dark silhouette, mirrored by which way he
is walking or facing, the same lower rung of the ladder the pot itself
draws on: a disc and a glow, not an animated sheet. A whole sprite
sheet earns its cost when there is more than one animation to tell
apart; a drudge this phase only ever walks or stands and throws, and a
silhouette says both. `tools/seed_wizard.py` is not touched and no
sibling seeder is added.

`app_draw_pots` and `shot_draw_pots` are now given the bag to draw
rather than always reading the wizard's own, so the same procedure
draws `pots` once and `drudge_pots` once — a pot in flight looks
identical either way, which is the point.

## Where he stands

He is placed `DRUDGE_SPAWN_X_OFFSET` (220 cells) to the right of
wherever the wizard spawns, dropped straight down onto the first solid
ground under that column the way `world_find_spawn` drops the wizard
onto his own. That puts him inside the Coalmine, past the mouth the
wizard walks in through, so the first thing the cave asks of a new
player is to notice him before he notices them — not stumble over him
in the first three steps. `./bin/shot player=1 w=512` (wide enough to
carry 220 cells past the spawn point) shows both of them in the one
picture.

## The numbers

| Constant | Value | What it does |
| --- | --- | --- |
| `DRUDGE_MAX` | 4 | drudges the bag can ever hold |
| `DRUDGE_BODY_W` | 10 | cells, what collides |
| `DRUDGE_BODY_H` | 12 | cells, what collides |
| `DRUDGE_WALK_SPEED` | 22.0 | cells per second on patrol |
| `DRUDGE_PATROL_LEG` | 60 | cells walked before the leash turns him anyway |
| `DRUDGE_SIGHT_RANGE` | 140 | cells, centre to centre |
| `DRUDGE_ALERT_HOLD` | 30 | ticks his sight of the player is remembered after it breaks |
| `DRUDGE_THROW_INTERVAL` | 240 | ticks between throws, 4 seconds |
| `DRUDGE_THROW_SPEED` | 110.0 | cells per second, along the aim |
| `DRUDGE_THROW_LOB` | 70.0 | cells per second of lift |
| `DRUDGE_SPAWN_X_OFFSET` | 220 | cells right of the wizard's own spawn |

Gravity and terminal fall are not repeated here: they are
`PLAYER_GRAVITY` and `PLAYER_MAX_FALL`, the same numbers a pot falls
by, because a drudge falls exactly as either one does.

## What this phase leaves out

- **No chase, ever, in this phase or later without a separate
  decision.** He does not turn toward the player's position, does not
  speed up, and does not remember a place to walk back to. Every rule
  above only changes which way he *looks*.
- **No health, no death, no damage to the player.** A blast grades the
  world under him and under the player exactly alike, and neither one
  reads it, because neither one can be hurt yet.
- **No climb, no jump, no flight.** A one-cell lip the wizard steps
  over without slowing is a wall to a drudge, and he turns at it.
- **No sprite sheet.** He is two rectangles, not twenty-four frames.
- **No sound, and no line of dialogue.** He notices the player only in
  the ways the numbers above say he does; nothing about that is acted
  or spoken yet.
- **One drudge.** `DRUDGE_MAX` leaves room for more, and `drudge_place`
  is only ever called once, at the one spawn point this note names.
