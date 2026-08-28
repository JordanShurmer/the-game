# The drudge

The first bad guy. He was a miner once, and the coal took the rest of
him. He walks the same stretch of tunnel he has always walked, back
and forth. He does not chase, and he does not give up the walk for
anything, even you. But if he sees you, he faces you, and every four
seconds or so he lobs a pot of black powder in your direction. He is
not fair. He just wants you gone. He carries a lit lamp, so a careful
player sees him first. This note says how he is built, the numbers he
moves by, and what this phase leaves out.

## He is a fixed bag, like the pots he throws

`src/drudge.odin` holds him. A `Drudge` is thirty-six bytes — a
position, a fall speed, how far he has walked this leg, an animation
clock (the same role `Player.anim` plays for the wizard), which way he
is walking, whether he is on the ground, how many ticks he still
remembers seeing you, and how many ticks until he may throw again —
and a `Drudge_Bag`
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

## Sight: seeing him before he sees you

A drudge sees the player when all three hold:

1. **Range.** The player is within `DRUDGE_SIGHT_RANGE` (30 cells) of
   him, dead centre to dead centre. This is well under
   `DRUDGE_SPAWN_MIN_DIST` (50 cells, see "Where he stands"), so a
   player who has just found him is never already inside it — there is
   always at least 20 cells of dark tunnel to approach through unseen.
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

### He carries a lamp, so you see him first

The whole point of `DRUDGE_SIGHT_RANGE` sitting well under
`DRUDGE_SPAWN_MIN_DIST` is that the player gets a warning first: a
drudge carries a lit lamp, floods light around himself as he walks
(`DRUDGE_LAMP_REACH`, 25 cells, roughly the same shape as the pot's own
fuse light — see `DRUDGE_LAMP_FALL`), and that pool of light is a
bobbing point of warmth in an otherwise dark tunnel, visible on screen
long before the player is anywhere near his `DRUDGE_SIGHT_RANGE`. Reach
does not need to exceed sight range for this to work — the pool is
drawn on screen at whatever distance the camera can see it, not only
within the reach that lights the terrain around him.

The lamp's brightness and colour are not its own: they are `Fire`'s,
the same material the pot's own burning fuse already borrows in
`light_throw_pots` (`src/light.odin`). A lamp is a flame, so this is
not a stretch, and it buys something concrete. `data/materials.txt`
sat at exactly 32 rows before this phase, and at the time
`SANDBOX_WIDE_IDS` in `src/sandbox_step_asm.odin` capped the
hand-written AVX2 weight lookup — the fast path the whole sandbox
physics loop runs through — at 32 material ids, so a 33rd row for the
lamp's own light would have silently turned the fast path off for the
entire game, not just the drudge. The lookup has since been widened to
64 ids. `test_the_shipped_materials_still_fit_the_wide_lookup`
(`src/sandbox_step_asm.odin`) exists so the next feature that reaches
for a new material row finds out immediately, in a test, rather than
in a slower benchmark nobody was watching. Only how far the lamp's
light reaches and how fast it falls off are code — `DRUDGE_LAMP_REACH`
and `DRUDGE_LAMP_FALL` — the same split every other light in the world
keeps between "how bright" (a material) and "how far" (a constant
beside the thing that carries it).

The lamp is drawn twice over: it lights the terrain near him, the way
the orb lights terrain near the wizard, and it is also drawn as a
small glow circle at his position — `DRUDGE_LAMP_HALO`,
`DRUDGE_LAMP_BLAZE`, `DRUDGE_LAMP_PEAK` — the same way the pot's own
fuse ember and the wizard's own orb are, so it reads on screen as a
point of light and not only as a faint wash on the rock beside him.

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

He was a miner, and the coal took the rest of him: short and stooped
from years bent to the seam, a small bowed head, coal blacks and soot
greys, and a lit lamp held out in front of him low — the one warm
thing on him, and his tell in the dark. That silhouette is nothing
like the wizard's own: the wizard is tall, upright, and blue, under a
tall hat and a robe to the ground; the drudge is short, hunched
forward, and colourless except for the one lamp he carries. Two
stacked rectangles said "a dark shape" but not "a miner," and reading
him at a glance as a person distinct from the wizard is worth a real
sheet.

`tools/seed_drudge.py` draws `data/sprites/drudge.png`, the wizard's
own pattern held to a second figure: `--check` holds the file on disk
to the rules, `--seed N` asks another hand to draw it, and he is built
from parts — a stooped torso, a bowed head, two legs, a throwing arm,
and a lamp arm — driven by per-frame numbers, not from one picture.

**Three rows, because that is everything he does.** `docs/drudge.md`
already says he never runs, jumps, flies, or dies; a sheet with a run
row or a death row would hold frames nothing in the game ever plays,
the same ponytail cut the wizard's own six rows already make.

  - `idle` (3 frames). He never truly stops patrolling once a tick
    runs him — "Patrol never stops" above is exact — but the moment
    before the first tick, and whatever `bin/shot` draws for him
    without being asked to run any ticks, is a real, drawn state, not
    a placeholder.
  - `walk` (6 frames). His patrol, back and forth.
  - `throw` (3 frames), not a loop: a windup, the release, and a
    follow-through, the same way the wizard's own `rise` and `fall`
    rows are three drawn moments rather than a cycle.

`drudge_motion` (`src/drudge.odin`) picks the row from his own state —
`.Throw` for a short window after `throw_cooldown` shows he has just
released a pot, `.Idle` while nothing has moved him (`walked == 0`),
`.Walk` otherwise — and `drudge_sprite_frame` (`src/drudge_sprite.odin`)
picks the column from an animation clock on `Drudge` itself, the same
role `Player.anim` already plays for the wizard.

**The body box and the drawing are two numbers that must agree, the
same way they do for the wizard.** `tools/seed_drudge.py` holds a
10x12 body box at `BODY_X, BODY_Y, BODY_W, BODY_H` inside a 22x26
frame — wide enough for the lamp held out and the throwing arm swung
back, tall enough for his bowed head above and a little stance below —
and `src/drudge_sprite.odin` asserts `DRUDGE_SPRITE_BODY_W ==
DRUDGE_BODY_W` and the same for the height, the way `src/sprite.odin`
does for the wizard. `--check` holds the sheet to it: his feet must
land on the bottom of the box, within `FOOT_SLACK`, or he floats.

**So do the drawing and the lamp.** `tools/seed_drudge.py` paints the
lamp at a fixed point relative to his own shoulder, and
`src/drudge.odin`'s `drudge_lamp_at` says where the light leaves him
and in what colour — the same split the wizard's own orb keeps between
the sheet and `light_orb_at`. `test_the_drudge_lamp_light_starts_where_the_sheet_draws_the_lamp`
(`src/light.odin`) reads the sheet at the point `drudge_lamp_at`
computes and fails if a redrawn drudge moves the lamp out from under
his own light. The lamp's ink itself is drawn in the two colours the
game already paints that light: `Fire`'s own RGB for the glow, and
`LIGHT_CORE` for its bright core, the same pairing `tools/seed_wizard.py`
uses for the orb.

**To redraw him:** edit `tools/seed_drudge.py` and run it with no
arguments; run it with `--check` before committing. If the body box or
the lamp's point move, update `DRUDGE_BODY_W`/`DRUDGE_BODY_H`
(`src/drudge.odin`) or `DRUDGE_LAMP_DX`/`DRUDGE_LAMP_DY` to match, or
the asserts and the light test will say so.

`app_draw_drudges` and `shot_draw_drudges` load and blit the sheet the
same way `app_draw_player` and `world_shot` do the wizard's own,
picking his row and column from `drudge_motion` and
`drudge_sprite_frame` and mirroring him to `drudge_facing`. The lamp
glow circle he has always carried is unchanged — the sheet draws the
lamp object, the glow draws its light — except that it, too, now
starts from `drudge_lamp_at` rather than his body's own centre.

`app_draw_pots` and `shot_draw_pots` are given the bag to draw rather
than always reading the wizard's own, so the same procedure draws
`pots` once and `drudge_pots` once — a pot in flight looks identical
either way, which is the point.

### Why a sibling loader, not a wider `src/sprite.odin`

`load_sprite_sheet` (`src/sprite.odin`) now takes the frame size and
grid as parameters, defaulted to the wizard's own numbers: that one
change is genuinely shared, since both sheets are read back from the
same PNG shape, and every existing caller is untouched by it. Past
that, `src/drudge_sprite.odin` is its own small file, not a widened
`src/sprite.odin`, because past the loader the two sheets share
nothing but the shape of the question: a different frame size, a
different row count, and a different motion enum with different names
and different meanings (`Drudge_Motion` has no `Run` or `Jet`, and
`Player_Motion` has no `Throw`). Threading a wizard-or-drudge switch
through `sprite_pixel`, `sprite_frame`, and every draw call that reads
them would have cost this file's whole size again in every one of
those procedures, for two sheets only two files (`Drudge` and this
one) ever ask a question of.

## Where he stands

`drudge_place` scans outward from the wizard's own spawn, column by
column, `DRUDGE_SPAWN_STEP` (2 cells) at a time, alternating left and
right, from `DRUDGE_SPAWN_MIN_DIST` (50 cells) out to
`DRUDGE_SPAWN_MAX_DIST` (2000 cells). A column only counts if it holds
solid, unembedded ground, is in the very biome region the wizard's own
spawn sits in, and — the newest of the four — is underground. The
drudge is placed at the first column that answers all of them.

That second test replaced a version of this phase that placed him a
fixed `220` cells to the right of the spawn and dropped him straight
down, with nothing checking what he landed on. In the shipped Gallery
biome that put him on the far side of an undiggable Bedrock wall: on
solid ground, technically not embedded, and completely unreachable, no
digger the wizard carries can open a way through Bedrock. The test
guarding this only checked that he landed roughly the right distance
away, so it passed while the drudge himself was a dead end. Scanning
for the wizard's own biome region instead means he can only ever land
somewhere the same cave system the wizard spawns into actually
reaches, and `test_the_shipped_world_places_a_drudge_the_player_can_reach`
now proves it by walking the wizard there with `sim_step_player`, the
way a player really would, rather than trusting a distance check to
stand in for reachability.

**The fourth test is that he is underground.** The first three checks
above pass just as happily on solid ground beside the pond as they do
in a mine shaft — solid, unembedded, in the wizard's own region, all
true of the shore too — and in the shipped world the nearest ground
answering them was exactly that shore: the one calm, pretty place in
the game, and not where a miner belongs. `drudge_has_ceiling`
(`src/drudge.odin`) is the simplest test that rules it out: solid rock
somewhere within `DRUDGE_SPAWN_CEILING` (24 cells, twice his own body
height) above the top of his body box. Open sky runs on for hundreds
of cells before it ever meets ground, so no column under it can pass;
a low outcrop over an otherwise open cave counts, and should — it does
not have to be the roof of the room he ends up standing in, only proof
that rock, not sky, sits over this spot. `drudge_ground_at_column`
already scanned downward through every column looking for the first
solid footing; adding the ceiling test to what it accepts is enough on
its own to make it search further down, and further out, past any
shelf that is solid ground in the right biome but still open to the
sky above — no separate downward or outward search was needed.
`test_the_shipped_world_places_a_drudge_underground` proves the
shipped drudge himself passes it, and
`test_the_shipped_world_places_a_drudge_the_player_can_reach` still
passes unchanged, because the ceiling test only narrows which ground
counts; it adds no way to land him somewhere his three other
guarantees would not already have allowed.

## The numbers

| Constant | Value | What it does |
| --- | --- | --- |
| `DRUDGE_MAX` | 4 | drudges the bag can ever hold |
| `DRUDGE_BODY_W` | 10 | cells, what collides |
| `DRUDGE_BODY_H` | 12 | cells, what collides |
| `DRUDGE_WALK_SPEED` | 22.0 | cells per second on patrol |
| `DRUDGE_PATROL_LEG` | 60 | cells walked before the leash turns him anyway |
| `DRUDGE_SIGHT_RANGE` | 30 | cells, centre to centre |
| `DRUDGE_ALERT_HOLD` | 30 | ticks his sight of the player is remembered after it breaks |
| `DRUDGE_LAMP_REACH` | 25 | cells the lamp's light floods out to |
| `DRUDGE_LAMP_FALL` | see source | how the lamp's light falls off with distance |
| `DRUDGE_LAMP_HALO` | 5 | cells, the radius of the lamp's glow circle |
| `DRUDGE_LAMP_BLAZE` | 2 | cells, the radius of the lamp's bright core |
| `DRUDGE_LAMP_PEAK` | 0.85 | how strongly the lamp's glow is drawn |
| `DRUDGE_THROW_INTERVAL` | 240 | ticks between throws, 4 seconds |
| `DRUDGE_THROW_SPEED` | 110.0 | cells per second, along the aim |
| `DRUDGE_THROW_LOB` | 70.0 | cells per second of lift |
| `DRUDGE_SPAWN_MIN_DIST` | 50 | cells, the nearest the placement scan may land him |
| `DRUDGE_SPAWN_MAX_DIST` | 2000 | cells, bounds the placement scan |
| `DRUDGE_SPAWN_STEP` | 2 | cells between one candidate column and the next |
| `DRUDGE_SPAWN_CEILING` | 24 | cells: solid rock must be within this far above his head, or the column is not underground |
| `DRUDGE_LAMP_MIRROR` | -0.5 | cells, where the lamp point is measured from |
| `DRUDGE_LAMP_DX` | 9.2 | cells, how far the lamp sits ahead of him, toward the way he faces |
| `DRUDGE_LAMP_DY` | -5.0 | cells, how far above his feet the lamp sits |

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
- **No run, no jump row, no death row on the sheet either.** He has
  three animations because he only ever does three things; a fourth
  row would be frames nothing in the game plays.
- **No sound, and no line of dialogue.** He notices the player only in
  the ways the numbers above say he does; nothing about that is acted
  or spoken yet.
- **One drudge.** `DRUDGE_MAX` leaves room for more, and `drudge_place`
  is only ever called once, at the one spawn point this note names.
