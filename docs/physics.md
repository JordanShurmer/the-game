# Environmental physics

The sandbox says what a rectangle of the world does next. This note
says what it must do, what it must not do, and in which order to build
it.

Read `docs/mcp.md` for the sandbox as it stands and `docs/player.md`
for the wizard. This note adds reactions, explosions, digging,
breaking, a hand painted gallery of rooms, and the join that lets the
wizard walk on the physics instead of on a picture of it.

## What Noita does, and which parts we take

Noita simulates every pixel. A pixel is a material, and a material is
a small set of numbers. Simple rules over those numbers give the
behaviour the game is known for.

| What Noita does | What we do |
| --- | --- |
| Powder falls and piles | Already done |
| Liquid falls, pools, and layers by density | Falling and pooling were done. Layering up and down came with "The rise rule"; layering side by side came with "Displacement". Pooling was not enough either: see "The reach is the flatness" |
| Liquid finds its level | **New**: `sandbox_flow`, and the `spread` of a material |
| Liquid carries a head, so a submerged opening levels both sides | **New**: `sb.head` and `sandbox_press`. Noita does not do this one |
| Gas climbs and gathers under a ceiling | Climbing was done. Gathering was not: a gas heaped in the corner it came up in. `sandbox_flow` runs it along the roof |
| Fire spreads along fuel and leaves smoke | Already done |
| Wood burns for a time, then becomes ash | Data only: `burns_to` a burning material with a `lifetime` and a `decays_to` |
| Water quenches fire and makes steam | **New**: the reaction table |
| Water on lava makes obsidian and steam | **New**: the reaction table |
| Acid eats material and is used up | **New**: the reaction table |
| Ice melts near heat | **New**: the reaction table |
| Explosions cast rays that hard material stops | **New**: `sandbox_explode` |
| An explosion turns nearby solid into falling rubble | **New**: `crumbles_to` |
| Spells dig material the tool is strong enough for | **New**: `sandbox_dig` |
| Hand painted rooms placed in the generated world | **New**: `generator = image` |

Five things Noita does that we do **not** build in this phase. Each
one is named here with the rung that would add it, so that a later
reader knows the gap is a decision and not an oversight.

- **No rigid bodies.** Noita cuts a pixel region into a polygon,
  hands it to a physics library, and writes the result back as
  pixels. A crate that tips over needs that. Our crates are cells: a
  wooden crate burns, an ice crate melts, a sand crate crumbles, and
  none of them rotate. The rung that adds rotation is marching squares
  over a connected component plus a body that carries its own cells.
- **No support test.** A solid never asks whether the ground under it
  is still there. A rock shelf with nothing below it hangs. Crumbling
  is local to the damage that caused it. The rung that adds it is a
  flood fill from the anchored cells of a chunk, run only where a
  chunk was cut.
- **No siphon, and no sideways exchange between liquids.** A pool finds
  its level and carries a head now -- see "The reach is the flatness"
  and "The head and the press" -- so a U bend stands level in both its
  arms and a standpipe fills off the cistern beside it. Two things it
  still will not do.

  **The head goes down and along, never up over a sill.** Nothing in
  the field carries tension, so an inverted U does not run: a body
  cannot pull water over a lip and down the far side of it. And the
  walk that spends a head reads one row, so two columns equalise when
  they lie on a common row of their own liquid within `spread` cells of
  each other, and not otherwise. That is the honest shape of
  communicating vessels here.

  **A liquid never goes through a powder.** It displaces its own kind
  and it steps into emptiness, and that is all: a pool of quicksilver
  standing against a bank of sand stops at the face of it, even though
  sand is the lighter of the two. Without that guard it tunnels
  straight through the bank -- measured, from a span of 21 cells to 78
  in two hundred ticks, and the chunk never sleeps. What a liquid soaks
  into is a question about porosity, which nothing here has; brush is
  the one material that answers it, and it answers with the sieve rule.

  **No cohesion, and no surface tension.** A grain thrown clear of the
  body during a collapse stays clear, a single cell of water on a wide
  dry floor sits as a bead for ever, and nothing draws either back. A
  fire in the body cannot cross the gap to it.

- **No momentum.** A cell of water carries no velocity, so water
  leaving a spout in the side of a cistern drops down the wall
  rather than arcing away from it, and a wave does not slosh. What
  coherence a stream has comes from the shape it runs through, not
  from anything it remembers. The rung that would add it is a signed
  byte a cell -- which way this fluid is going and how fast -- swapped
  along with the cell, read by `sandbox_flow` in place of the side
  hash, and gained and spent by the moves themselves. It costs one
  byte a cell, which is 64 megabytes on the whole map, and it
  has to be expressible in the vector intent pass.
- **No temperature field.** A number per cell for heat would cost as
  much memory as the cells and buy behaviour that the reaction table
  already gives. Fire, melting, freezing and boiling are all pairs of
  materials that meet.

## What the codebase decides for us

1. **A new material and a new reaction need no code.**
   `docs/mcp.md` already makes that promise. Everything below holds it.
   Reactions are rows in `data/materials.txt`, not a switch in Odin.
2. **`Material` is 24 bytes and the `#assert` says so.** Its tail is
   where a new number goes while there is room in the padding: `force`
   went there, then `luminosity`, then `spread`. One byte is left. The
   next field after that costs eight, so it had better be worth it.
3. **Hot fields in the struct, cold fields in parallel tables.**
   `crumbles_to` is read only when a blast lands, so it is a cold
   table beside `decays_to` and `burns_to`.
4. **A run repeats.** The sandbox is a function of the seed, the
   region, and the command list. Every random number in the step is a
   hash of the place and the tick, not a draw from a running
   generator, so a cell gets the same number whatever order the scan
   reaches it in. Explosions draw nothing at all: the rays are fixed
   angles. `sandbox_checksum` stays the whole test for both.
5. **A picture is the check.** `bin/shot` learns to run the sandbox,
   so every room of the gallery can be judged from a terminal, before
   and after the physics runs.
6. **One path for a hand and a model.** Every new command reaches the
   sandbox through `Input_Queue`, and every new MCP tool calls the
   same procedure the window calls.

## The materials

Fifteen new materials, all in `data/materials.txt`. The list is
chosen room by room from the gallery below: nothing is added that no
room shows.

| Material | State | Density | Hardness | What it is for |
| --- | --- | --- | --- | --- |
| `Wood` | Solid | 0.7 | 3 | burns, and holds a shelf up until it does |
| `Burning_Wood` | Solid | 0.7 | 3 | wood on fire; a lifetime, then ash |
| `Ash` | Powder | 0.6 | 1 | what is left |
| `Coal` | Solid | 1.5 | 4 | the mine, and a slower fire |
| `Burning_Coal` | Solid | 1.5 | 4 | coal on fire; a longer lifetime |
| `Ice` | Solid | 0.92 | 2 | melts near heat |
| `Snow` | Powder | 0.4 | 1 | melts faster |
| `Obsidian` | Solid | 2.6 | 9 | what water leaves in lava |
| `Gunpowder` | Powder | 1.7 | 1 | one grain pops, and a pile is many of them |
| `Tnt` | Solid | 1.6 | 2 | a block that goes off harder |
| `Gravel` | Powder | 2.2 | 2 | what blasted rock falls as |
| `Flammable_Gas` | Gas | 0.15 | 0 | a pocket that lights all at once |
| `Toxic_Sludge` | Liquid | 1.4 | 0 | the heavy layer in the density tank |
| `Steel` | Solid | 7.8 | 12 | a wall the player cannot dig |
| `Bedrock` | Solid | 3.0 | 255 | a wall nothing can touch |

`Bedrock` is the gallery. Every room wall is bedrock, so a blast in
one room cannot reach the next one, and the museum survives a visitor.

One existing material changes: `Rock` gains `crumbles_to = Gravel`.

A material with no `crumbles_to` crumbles into **itself**. That is not
the same default `decays_to` and `burns_to` take, and the difference
is deliberate. Those two are gated by another field: a `lifetime` of
-1 means `decays_to` is never read, and a `flammability` of 0 means
`burns_to` is never read. Nothing gates `crumbles_to`, because a blast
asks every cell it touches what it crumbles into. Defaulting to Air
would erase every material a blast passes near. Defaulting to the
material itself makes "become what you crumble into" a no-op, so no
caller needs a second field to ask whether a material crumbles at
all.

## The reaction table

A reaction is a pair of materials that meet and both change.

A pair may name more than one row, tried in the order written, all on
one roll. `docs/alchemy.md`, "A chain of rows", says how that works
and what it builds: the poison and the water, and the light the two
throw off.

`data/materials.txt` gains one reserved section, the way
`data/biomes.txt` already has `[Map]`. The same parser reads it.

```
[Reactions]
# a + b -> c + d   chance out of 255
Water + Fire          -> Steam + Steam       255
Water + Lava          -> Steam + Obsidian     40
Water + Burning_Wood  -> Steam + Wood        120
Acid  + Rock          -> Air   + Air          10
Ice   + Fire          -> Water + Fire        160
Flammable_Gas + Fire  -> Fire  + Fire        255
```

**The order of the operands is the order of the results.** The cell
that holds `a` becomes `c`, and the cell that holds `b` becomes `d`.
`Acid + Rock -> Air + Air` therefore means that the acid is used up
along with the rock, which is why a pool of acid eats a hole the size
of the pool and then stops.

The loader stores each row twice, once as written and once with both
sides swapped, so a lookup never has to try the pair both ways.

```odin
// 8 bytes, and the #assert holds it there.
Reaction :: struct {
	c, d:   u16, // what it becomes
	chance: u8,  // out of 255, per probe
	next:   i16, // the next row for the same pair, -1 at the end
}
#assert(size_of(Reaction) == 8)
```

A row does not name what meets: the key that reaches it says that. The
table carries three things:

```odin
reactions: []Reaction, // every row, both ways round
reaction_at: []i16,    // n*n; the head of a pair's chain of rows, or -1
partners: []u64,       // n; one bit per partner, the coarse filter
```

`reaction_at` is a dense square of `i16`, indexed `a*n + b`, holding
the first row of the pair's chain — `next` walks the rest, and
docs/alchemy.md, "A chain of rows", says how. With the 54 materials
the game ships that is 2916 entries, or 5832 bytes. A table of 200
materials would cost 80 KB, which is the bound worth knowing and far
past what this game needs.

The `.Reacts` bit of a cell's `work` is the gate that keeps the step
cheap. Air is in no row, so the common cell pays one bit and nothing
else.

**One roll per cell per tick, against a side that has a partner on
it.** The step walks the four sides anyway, because whether any side
could react is what decides that the cell is worth a look next tick.
So it rolls once, against one of the sides that has something to react
with, and not against one of the three that are empty.

It used to roll against one of the four sides whatever was on them,
and that made a chance of 255 mean "in about four ticks" rather than
"now". A pair that only meets for one tick then usually missed each
other: a flame and the water above it change places on the tick they
meet, so water quenched fire about half the time. Measured over a
hundred seeds: 53 of 100 before, 100 of 100 after.

The cost is the same, and the reading of `chance` is now the plain
one: it is the chance that the reaction happens on a tick when the
pair are touching.

Both cells are marked in `moved`, so a cell reacts at most once per
tick and cannot also fall in the same tick.

## Burning, without new code

Wood does not need a burn timer in the step. It needs three rows of
data:

```
[Wood]          burns_to = Burning_Wood
[Burning_Wood]  state = Solid   lifetime = 300   contact = Burns   decays_to = Ash
[Ash]           state = Powder
```

`Burning_Wood` is a solid, so it stays in the wall. `contact = Burns`
makes the existing `sandbox_spread_fire` run from it, so the fire
walks along the beam. `lifetime` and `decays_to` are the existing
decay path, so after 300 ticks the beam is ash and the ash falls.

This is rung two of the ladder: the mechanism is already in the step,
and burning wood is a use of it. Coal is the same shape with a longer
lifetime.

## The rise rule

A liquid only ever tried to sink. That is not enough to make two
liquids layer, and the reason is the scan order.

The scan runs from the bottom row up, so of a heavy cell resting on a
lighter one, the lighter cell below is always stepped first. It
spreads sideways within its own pool, marks itself moved, and the
heavy cell above is then refused for the whole of that tick. It is
refused again on the next tick, and every tick after it, because
nothing about the arrangement has changed.

Measured: oil, water and toxic sludge poured into one tank settled
part of the way and then held **27 heavy cells resting on lighter
ones, unchanged from tick 800 to tick 12000**.

So a liquid now also rises. A liquid whose upstairs neighbour is a
denser liquid changes places with it, which is the rule gases already
have. The same measurement then reaches **zero** by tick 800, and the
three layers separate further than they ever did.

Two things make the rule safe:

- `Rise` refuses a target of the same density, so a settled pool of
  one liquid does not swap up and down for ever, and its chunk still
  goes back to sleep.
- After the swap the pair is in the order it wanted, so it does not
  swap back.

## The reach is the flatness

The rise rule made two liquids layer. It did not make one liquid read
as water, and for a long time nothing did. Measured, before this:

| What was set up | What it did |
| --- | --- |
| a column of water 6 wide and 30 tall, on a flat floor 200 long | spread to x=21 and froze there by tick 50, holding a 45 degree wedge, unchanged at tick 12000 |
| a tank with a wall across it and a hole at the foot of the wall | eight cells crossed, and then nothing |
| a dam broken in a box 120 long | the front reached x=59 and stopped, holding water 26 deep where a level pool would have been 10 |
| a room 58 wide and 38 tall, one puff of gas released in a corner | a heap 11 wide against that wall, unchanged from tick 100 |

`sandbox_spreads` was the whole of it. A liquid could step aside only
onto a cell that had a drop under it (`downhill`) or something
pressing from above (`pressed`). Of a one-cell step down in its own
surface, neither is true: the cell beside it is empty, but the cell
under that one is the neighbour's own water, and the cell over it is
air. So a one-cell step is a place a liquid will not step onto, and a
staircase of one-cell steps is a shape it holds for ever. That is a
powder's angle of repose, drawn by a liquid.

Nothing read further than one cell, so nothing could see that two
cells along the row there was a place to fall.

**The packing rule survives, and only that.** A liquid leaves an empty
cell alone while fluid sits over it, because that fluid is about to
fall in. Without it the scan reaches a row before the row above it, a
cell takes the hole beside it and leaves a hole where it was, and the
cell that was going to drop into the first hole is refused: the holes
then walk from side to side for ever and the pool keeps every one of
them. A pool that packs also goes to sleep, where one that walks its
holes keeps its chunk awake for the life of the world. A gas keeps the
same rule, mirrored: the row a fluid came from is over a liquid and
under a gas.

**So a stopped fluid looks along its row.** `sandbox_flow`: a liquid
looks for a cell it can sink from, a gas for one it can climb from, as
far as the material's `spread` says, and goes to the first one it
finds. It goes the whole way in one step: the cells it crosses are all
of one kind, so arriving at the far end is nearly the same picture as
walking there, and walking there would leave a cell standing in the row
for the water behind to trip over, which measurably stops the flow.
(Once a fluid may cross another fluid -- see "Displacement" -- the
picture is no longer exact: the heavy cell goes the whole gap and one
light cell comes back a cell the other way. The count is conserved and
it settles cleanly, but that is the sentence to push on.) `ahead` is +1 for a liquid and
-1 for a gas, and that is the only difference between the two.

The reach is the flatness. What settles is a surface that falls about
one cell every `spread` cells, because a terrace shorter than the
reach is one a cell can see across and step off. Measured, on the same
column of water on the same 200-cell floor:

| `spread` | Where the water reached | How far its surface fell |
| --- | --- | --- |
| 8 | x=48 | 1 cell in 8 |
| 16 | x=63 | 1 in 16 |
| 64 | x=199, the whole floor | 4 cells over 200 |

So it is the one number that says how runny a fluid is, and it is a
column in `data/materials.txt`: water 64 and level, oil 24, sludge 12,
lava 3 and keeping the slope of a flow.

**What it costs is nearly nothing, because it is free where it does not
apply.** The look stops at the first cell it cannot enter, and inside a
body of water that is the cell next door, so a submerged cell pays one
comparison. Only a cell with open row beside it looks far, and a pool
has those at its two ends. Measured, `./bin/bench`, interleaved best of
seven -- read the pairs, not the digits, and see "Measure before you
optimize" in AGENTS.md for the method:

| Bench | Before | With the look |
| --- | --- | --- |
| Lake, 200 ticks | 4.815 ms a tick | 4.952 (+3%) |
| Coalmine, 100 ticks | 2.142 | 2.251 (+5%) |
| Homelands, 300 ticks | 1.358 | 1.371 (+1%) |
| Cavemouth, 300 ticks | 3.499 | 4.031 (+15%) |

Cavemouth is the one that pays, and it pays because it has water in it
that used to be stuck and now runs. A homelands region with no mill in
it comes out bit-identical and costs the same.

### Two things tried there that did not pay

Read this before trying them again.

- **A cap on how far a fluid may travel in a tick**, beside how far it
  looks: a second per-material number, and the cell moves `min(k,
  speed)` cells instead of the whole gap. The argument for it is that
  a fluid which crosses its reach in one tick leaves an empty shelf
  behind it, and a race with nothing in it does not read as a race.
  Measured, with the floor at 8 cells a tick: the whole suite passes
  and the mill is not distinguishable in a picture at tick 25, 90 or
  1500, a long shelf fed by a spout holds a thinner sheet rather than
  a steeper pile, and the tick costs 25% more on both benchmarks
  (Lake 5.12 -> 6.53 ms, Coalmine 2.29 -> 2.87), because the water
  takes more ticks to settle and every one of them is work. A quarter
  of the tick for a difference nobody can point at is not a trade.
- **The two numbers the step reads a cell at a time, moved out of the
  24-byte `Material` and into byte tables beside `weight` and `kind`.**
  This one is *in*, and it is in for the shape rather than for the
  clock: the checksums are identical and nine interleaved runs put it
  inside the noise on both benches (Lake best 7.489 against 7.664,
  Coalmine 2.883 against 2.848). `sandbox_flow` is called once for a
  moving fluid cell, not once a cell, so there was less there to win
  than the phrasing of "Where the tick goes now" suggests. It is kept
  because a `Material` load in the step is the thing that shape exists
  to keep out, and the next number that goes there will be read the
  same way.

- **The side a fluid looks first, remembered in a byte a cell.** The
  obvious form of momentum, and it buys nothing, for a structural
  reason worth writing down: `sandbox_flow` looks BOTH ways and takes
  the first way on it finds, so which way it looks first is not
  something the world can feel. Momentum has to change what a cell may
  **do**, not the order in which it asks. See "No momentum" above for
  the form that would.

### The head and the press

The look levels a free surface. It does nothing at all for water that
is already under water, because a submerged cell has nowhere to step:
before this, a tank with a wall across it and an opening at the foot of
the wall settled with 719 cells on one side and 108 on the other, their
surfaces 22 rows apart, and held that for ever. Pressure is what closes
that, and pressure is a field.

**The field.** One `u8` a cell, `sb.head`. The low seven bits are how
many cells of the same liquid stand over this one; bit 7 says the row
term won.

    column  = (the cell over this one is the same liquid) ? min(127, head[above] + 1) : 0
    carried = (the cell over this one is the same liquid) ? head[above] & 0x80 : 0
    head    = max(column, head[left] and head[right] where they are the same liquid)
    out     = head | (head > column ? 0x80 : carried)

The column term alone is a depth count, and a depth count knows nothing
about the water round the corner. The **row term** -- the greatest head
of a same-liquid neighbour on this row -- is what walks a head along a
passage and out of the far end of it, and it is why this is a field and
not a column. It is a running maximum, so it travels the way the sweep
goes: the step alternates the direction by tick, and the fill sweeps
both ways.

Bit 7 has to be **inherited down a column** (`carried`), because at the
foot of a short shaft the column term is one greater a row and would
otherwise swallow the very difference it is carrying. It never sticks:
it is recomputed every pass and clears from the top down as soon as the
row term stops winning.

**The pass marks nothing, ever.** A head is one number for a whole body
of water, so a cell that moves anywhere in a lake changes it
everywhere. A version that woke what it changed took Lake from 7.3 ms a
tick to **39.6**. The field travels only where matter is already awake,
which is the only place anything can act on it.

**And so it has to be seeded.** Water drawn into the world at rest
sleeps on its second tick -- long before a head could travel the depth
of it -- so a pond that is authored full would never learn it stands
over anything. `sandbox_head_fill` gives a sandbox the whole field when
it is filled from the world: one pass down, both ways along every row,
which is all the relaxation a body needs when nothing has moved yet.
Without it a U bend painted full on one side does not move a cell.

**The press.** One intent arm, the lowest priority of all: a liquid
with bit 7 set, standing on something that is not its own kind, asks to
go up. Standing on something else is what makes a column ask once a
tick rather than once for every cell in it.

The move is not a climb. The cell that presses does not move at all: it
looks along its own row, through its own liquid, for a column standing
**two** clear cells over the top of its own, and moves the top cell of
that column onto the top of this one. Every cell between is the same
liquid, so that is the same picture as shifting the whole run one cell
along, and it leaves no hole. A cell climbing into the air over its own
head instead **foams**: it rises, the cell under it falls back into the
hole, and the pair swap for ever.

Two cells and not one is the anti-jitter rule, the same shape as the
rise rule's strict test. With one, a press drops the far surface a cell
and lifts this one a cell, so a difference of one crosses over and
presses straight back: measured, a pool locked into a permanent
2,3,2,3, thirty swaps a tick, and never slept.

**What it buys**, measured:

| Shape | Without | With |
| --- | --- | --- |
| a tank with a gap under the waterline | 719 cells one side, 108 the other, surfaces 13 and 35 | 418 and 407, both surfaces at 24 |
| a standpipe off a cistern | pipe holds 8 cells, surfaces 12 and 41 | pipe holds 120, surfaces 15 and 13 |
| a U bend, painted full on one side | right arm 30 cells, surfaces 6 and 38 | surfaces 22 and 21 |
| a still pond, 300 ticks | 0 chunks awake, 0 cells moved | 0 chunks awake, 0 cells moved |
| a pond half under a rock lid, 1200 ticks | no bubble | no bubble |

**The still pond is safe structurally, not by tuning.** In a level pool
the head is a function of the row alone, so every same-liquid neighbour
on a row holds the same number, the row term never wins, bit 7 is never
set anywhere, and `sandbox_presses` is false for every cell. The arm is
not merely declined -- it is never reached, the row's `moving` stays
false, and APPLY never runs.
`test_a_settled_pond_goes_back_to_sleep` and
`test_a_pond_under_a_lid_holds_no_bubble` hold both halves of that.

**What it costs**, `./bin/bench`, interleaved best of seven:

| Bench | The look | And the press |
| --- | --- | --- |
| Lake, 200 ticks | 4.952 ms a tick | 7.435 (+50%) |
| Coalmine, 100 ticks | 2.251 | 2.764 (+23%) |
| Homelands, 300 ticks | 1.371 | 1.509 (+10%) |
| Cavemouth, 300 ticks | 4.031 | 4.655 (+15%) |

Plus one byte a cell, which is 64 megabytes on the whole map.

Lake is the honest worst case and is not a place: it is a whole region
of nothing but water and oil, all of it awake and separating. **In the
game the press does not show.** A headless run of 300 ticks standing in
the village spends 0.43 ms a tick in `Step_Rows` with it and 0.47
without, inside a frame that is otherwise sixteen.

Two things were tried to make the field cheaper and neither moved the
number: skipping it on dry rows -- which is in, because it is free, but
worth nothing where the water is -- and relaxing it only every fourth
tick. The cost is not the relaxation. It is that LOAD touches one more
array a cell and INTENT asks one more question of it, so what would
make it cheap is folding the head into LOAD's own loop rather than
reading a second array.

**The gas press was built and cut.** The mirror was free to write --
one sign, exactly as `sandbox_flow` does it -- so it was written: head
counts gas below, and the arm sends a pressed gas down. It never fired
once on the shipped world, and where it did fire it made things worse:
`test_a_gas_runs_along_the_roof_it_gathers_under` went from thirty
columns of roof to twenty-seven and failed. Hydrostatic head is the
wrong physics for a gas. What fills a room is volume pressure, and a
gas that has reached the ceiling as a one-cell sheet has no column to
redistribute. `sandbox_flow` already gives a gas the ceiling run, and
it does it better.

### Displacement: what a fluid moves through

The look levels a free surface and the press carries a head. Neither
does anything for two liquids standing side by side, and for a long
time nothing did: `room` asked whether the cell beside this one was
**empty**, so a liquid stepped aside onto air and onto nothing else.

Measured, before this: sludge, water and oil poured into one tank in
three columns settle into a perfect diagonal smear -- every row holding
all three, the counts shifting by one a row -- with not one cell
resting on anything lighter, bit-identical and fully asleep from tick
100 to tick 8000. It satisfies the rise rule exactly. It is a local
minimum, and no move of one cell escapes it.

So `room` is deleted, and what is left is the question a weight can
answer: **may this fluid move through that cell?**

    sandbox_shifts(self, side, behind, side_kind) =
        sinks(self, side) && (unclaimed(side, behind) || side_kind == .Liquid)

A liquid passes through anything lighter that is also a liquid, and
steps into an empty cell that nothing is about to fall into. A gas is
the mirror. Three things about that shape are load bearing:

- **The packing rule is asked only of an empty cell.** Displacing
  another liquid does not leave a hole to walk -- the two exchange --
  so there is nothing there to guard.
- **Only the arrival licenses the move.** `sandbox_flow` asks two
  questions now: may I pass through this cell, and is this cell a way
  on. The first opens the road; the second is still `sinks`. That is
  why this does not wander the way the naive version does: a liquid
  does not swap with its neighbour because the neighbour is lighter,
  it travels to a place it can sink from and exchanges what it passes.
- **Never through a powder.** Sand is lighter than quicksilver, and
  without a test of the neighbour's kind a pool of quicksilver tunnels
  through a sand bank, from a span of 21 cells to 78 in two hundred
  ticks, and never sleeps.

The same tank now settles into three flat bands inside a thousand
ticks -- oil, water, sludge, top to bottom -- and wakes no chunk. The
density room in the gallery is a narrow column because layering used
to need one; it could be a wide tank now.

**And the self-watch had to be narrowed with it.** Many more cells now
answer yes to "have you somewhere to step", and every one of them used
to reach the mark-and-look-again at the foot of `sandbox_flow`:
measured, a settled three-liquid tank cost 10 rows and 520 cells a tick
with 0 swaps, for ever. So a fluid keeps watch only if it looked across
open row. The argument for the watch is that what would let it on lies
further off than a swap can wake, and that is true along open row and
false through another fluid, where anything that changes is a
neighbour and a neighbour wakes it.

It costs no memory at all, and it is a deletion in the predicate: one
extra kind read in the plain path, one `wide_sides` pair in the vector
path.

### Waking what a fluid can see

A swap wakes the cells it touches and no more. That is enough while
matter moves one cell at a time, and it is not enough for a fluid that
reads a whole reach: a cell that moves changes the answer for water it
never touched. Two rules keep the sleep honest, and neither costs a
packed pool anything.

- **A fluid that moves wakes the band it looked across.** If it saw
  the way on `k` cells off, it was itself in view of any fluid up to
  `k` cells the other way, along the same open run and in the row over
  and the row under. The band is as wide as the look that earned it,
  so it costs what the flow costs.
- **A fluid with somewhere to step and nowhere to go keeps watch
  itself.** What would let it on is further off than a swap wakes, so
  it marks itself and looks again next tick. Only a fluid with an
  empty cell beside it at its own level ever gets there, which a
  packed pool has nowhere but at its two ends.

Without the first, a pond drains and leaves a shelf of itself stranded
up its own bank, because the water that could follow was asleep.
Without the second, the same happens more slowly and in more places.
With both, `test_a_settled_pond_goes_back_to_sleep` still finds every
chunk of a settled pond asleep and not one of its cells moving.

## The sieve rule

Brush — a standing crop, a hedge — weighs `CELL_WALL`, because nothing
the sandbox moves is heavy enough to push a stalk aside. But a crop is
not a roof: what falls on it should end up under it, on the ground
between the stalks, not resting on the canopy eleven cells in the air.

So brush sifts. A powder or a liquid standing directly on a cell of
brush trades places with it (`sandbox_sift`, a `.Sieves` work bit on
every brush material): the grain trickles a cell a tick toward the
ground, and the stalk rides up over what gathers at its foot, the way
a crop stands on a drift rather than under one. The brush cell is the
side that does the work, because the falling cell has already stopped
— its own intent saw a wall below and nothing more.

One brush cell in `BRUSH_WEAVE` (64) is woven too dense to pass. The
weave is a hash of the world position, not a roll per tick, so a dense
spot stays dense and the grain that lands on one stays lodged until
fire or the digger frees it. Over a crop eleven tall that leaves about
one grain in seven caught somewhere on the way down: the field is an
extremely porous material, not a strainer that holds everything.
`test_what_falls_on_a_crop_mostly_sifts_through_and_a_little_lodges`
measures both halves of that sentence.

## Explosions

```odin
// Cast rays from a point. Hard material stops them.
sandbox_explode :: proc(sb: ^Sandbox, table: Material_Table, cx, cy: i32, radius: i32, power: u8) -> (broken: int)
```

The model is Noita's: a blast is rays, not a disc, so a wall casts a
shadow and a corridor channels the blast.

1. Cast `max(24, radius * 6)` rays at fixed angles. Fixed, not
   random, because a replay must give the same crater.
2. Walk each ray one cell at a time, up to `radius` cells.
3. Each cell costs `hardness + 1` energy. The ray starts with
   `power` energy and stops when it runs out. Air costs 1, so a blast
   fades over distance even through open air. Rock costs 9. Bedrock
   costs 256, which stops any blast in one cell. The energy is an
   `i32`, because a `u8` cannot hold the cost of bedrock.
4. A cell the ray pays for becomes `Air`, or, inside the inner third
   of the radius, `Blast` on a roll under `EXPLODE_BLAST_ODDS` out of
   255 and `Air` otherwise. The inner third is what lights the fuel in
   the room; the roll is what keeps the blast a scatter of flame there
   rather than a solid disc with a compass-drawn edge, which also
   means far fewer cells are ever born to leave fire and then smoke
   behind.
5. Each cell that is cleared crumbles its four neighbours: a
   neighbour whose `crumbles_to` is set becomes that material. Rock
   becomes gravel and rains down.

So `power` reads as "how many cells of empty air this blast crosses".
A `power` of 64 crosses 64 cells of air or 7 cells of rock.

**A material with `force` above zero detonates instead of burning.**
`force` is expulsive force: the power and the reach of the blast a
material makes when it goes off. When `sandbox_ignite` or
`sandbox_spread_fire` reaches such a cell, a blast starts there with
`power = force` and `radius = force`.

**The explosion is a material as well.** `Blast` is a row in
`data/materials.txt` like any other: `Special` state, an expulsive
`force` of 36, a `luminosity` of 255, and a lifetime of 22 ticks, after
which it is fire. Every blast writes it into the cell it goes off in —
paying for that cell the way a ray pays for the cells it crosses, so a
blast set off inside bedrock leaves it standing — and step 4 above
writes it through the heart of the crater in place of the fire that
used to go there — so what a grain of gunpowder turns
into is the bang itself, and the bang burns the fuel around it, rises
like a flame, and is gone in a third of a second. The blast also
remembers the place in the sandbox's ring of bangs, which is what
lights the cave; `docs/lighting.md`, "The bangs", says how.

A pot of black powder takes its potency from that same row. `Blast`
carries the force of three grains of gunpowder, and
`test_the_pot_carries_the_grains_its_blast_is_made_of` holds the two
numbers in step.

The reach is the power, and not a fraction of it. A ray spends at
least 1 energy on every cell it crosses, so a blast of power p can
never reach further than p cells, even through open air. A smaller
radius stops rays that still have energy to spend, and the crater then
ends at a circle the material did nothing to earn. It showed as a
block of tnt that cleared the air around itself and left a rock wall
32 cells away untouched. A pile of gunpowder
therefore goes off grain by grain, each grain lighting the next,
which is the chain a pile should have.

**A blast never sets off a second blast in the same tick.** Every cell
a blast writes is marked in `moved`, so the step does not visit it
again this tick. The blast the first grain leaves reaches the next
grain on the next tick, and that grain detonates in its own hot pass.
Without this rule one grain of gunpowder recurses through a whole pile
inside one call and overflows the stack. With it, a pile takes a few
ticks to go off, which is also what a chain should look like.

### The blast grades what it meets

Hardness says how far a blast reaches: it is the cost of the ray, so a
harder wall eats more energy and stops it sooner. Density says where
the matter goes: it is not read until a ray has already paid for a
cell, and it grades that cell's own weight against the energy the ray
still carries there.

```odin
heft := max(i32(m.density * BLAST_LIFT), 1)
lift := energy * BLAST_LIFT / heft
```

`lift` reads as sixteenths of the ray's remaining energy per unit of
the cell's density: light matter under a strong ray lifts easily,
heavy matter barely lifts at all. The four rungs below are
`blast_verdict`, a pure function of a material and the energy a ray
still carries when it reaches it — nothing in it touches the sandbox,
so a test can hold it to this note without running a blast at all.
`sandbox_explode` switches on its result instead of computing the
rungs inline, checked in this order:

1. **`lift >= BLAST_SCATTER`, or the material is not `.Still`.** The
   cell clears exactly as it did before density mattered — Air, or,
   inside the inner third, Fire on the same roll step 4 above
   describes — and its `crumbles_to` is thrown outward along the ray,
   past the crater, the same way `sandbox_cut` throws its cuttings.
   Powder, liquid and gas are never `.Still`, so loose matter always
   takes this rung: it flies when it moves at all. A `.Still` material
   light enough can take it too, on lift alone; it still clears, but
   nothing is thrown if it has no `crumbles_to` to throw.
2. **`lift >= BLAST_CRUMBLE` and `crumbles_to` is not the material
   itself.** The cell becomes its `crumbles_to` in place. Nothing is
   thrown; the sandbox drops it on the next tick, the way any powder
   falls.
3. **`lift >= BLAST_CHIP`, or the cell has nothing to crumble into.**
   A still material with no `crumbles_to` — gold, steel, obsidian —
   lands here even at a lift the first two rungs would otherwise
   ignore, because it has nowhere else to go. One roll of
   `sandbox_chance` per cell: under `BLAST_CHIP_ODDS` out of 255 the
   cell goes to Air, a bite taken out of the face; the rest of the
   time it stands.
4. **Anything else, and every cell that stops a ray outright because
   `energy < cost`.** The cell stands, and the blast chars it: soot is
   written into the cell the ray came from, but only when that cell is
   exactly air and the cell it is charring is not. So soot sits on the
   open face of what stopped the blast, never floating in a pocket of
   air the ray never reached and never smothering the fire a rung one
   cell burns in the inner third.

A grain thrown by rung one flies `BLAST_FLING` cells per unit of lift
past `BLAST_SCATTER`, out to at most one radius past the crater, with
a small sideways jitter from `sandbox_chance` so a spray of gravel does
not land in a single file. `sandbox_throw` already refuses a `.Still`
grain and a cell that is not air, so a blast inside solid rock quietly
loses most of what it throws, and a blast in an open room sprays it.

Point blank — a cell that touches the blast's own origin cell — is the
most lift a material can ever be given, because lift only falls as a
ray spends more energy reaching further out. So point blank is enough
to say whether a material can ever scatter or crumble under a pot's
blast at all, and `test_a_pot_grades_the_shipped_materials_as_the_note_says`
checks exactly that: `blast_verdict` at `pot_power(table)` less the
one cell's own cost, against the row each material sits in below.

| Material | Density | Under a pot's blast, point blank |
| --- | --- | --- |
| `Gunpowder`, `Ash`, `Snow`, `Dirt`, `Sand` | 0.4 – 1.7 | scatter: not `.Still`, always rung one |
| `Wood`, `Ice` | 0.7 – 0.92 | scatter even so: too light for `.Still` to save them at the blast itself, though nothing is thrown, since neither has a `crumbles_to` |
| `Rock` | 2.5 | crumbles to gravel at the blast itself; chips or chars further out; never scatters |
| `Coal` | 1.5 | chips or chars: no `crumbles_to` to crumble into, and too dense to clear the way wood and ice do |
| `Obsidian`, `Steel` | 2.6 – 7.8 | chip: `.Still` with nothing to crumble into |
| `Gold` | 19.3 | so dense that even point blank a pot cannot chip it; every hit chars |
| `Bedrock` | 3.0 | never reached: hardness alone stops the ray |

### Looking at the ladder

Room 13 of the gallery ("Digging," world (512,-2688)) is eight vertical
strips of material, softest to hardest: dirt, sand, coal, wood, rock,
obsidian, steel, bedrock. It was built to show what the digger can
cut. It shows what a blast grades even better, because one picture
holds every rung at once.

```sh
odin build cmd/shot -out:/tmp/s -o:speed
S=seed=0x1AB   # the world the galleries are in; see docs/laboratory.md
/tmp/s $S x=512 y=-2688 w=128 h=128 scale=4 light=0 out=shots/r3_strips.png
/tmp/s $S x=512 y=-2688 w=128 h=128 scale=4 light=0 ticks=2 \
       explode=576,-2624,36,36 out=shots/r3_strips_wood.png
/tmp/s $S x=512 y=-2688 w=128 h=128 scale=4 light=0 ticks=2 \
       explode=613,-2624,36,36 out=shots/r3_strips_steel.png
```

The first blast sits on the wood and rock border. **Scatter** is the
crater it opens in the wood: the strip clears to Fire and Air right up
to the strip's own hardness-bought edge, the same rung a crater in
dirt or sand would show, because Wood is light enough to hit rung one
on lift alone even while `.Still`. **Crumble** is the rock beside it:
where the blast still has lift enough to break a face but not to clear
it, Rock turns to the lighter, warmer grey of gravel in place, a scoop
bitten out of the strip rather than a hole through it. **Char** is the
black flecks laced through both, on the rock side more than the wood:
soot sitting on whatever the ray could not afford to move at all. The
white heart of that crater is the blast material itself, two ticks
old; take the same picture at `ticks=30` and it has decayed to the
orange of the fire it leaves in the wood.
(One further step for a careful look: a soot fleck that lands beside a
cell the same blast clears crumbles again on the spot, into the pale
ash soot itself decays to — the ordinary "a cleared cell crumbles its
neighbours" rule did not stop applying just because rung four wrote
the neighbour.)

The second blast sits in the middle of the steel, well past where the
first blast's energy could ever reach. **Chip** is what is left to see
there: perhaps a dozen dark specks — a few cells rolled under
`BLAST_CHIP_ODDS` and went to Air, char took the rest — on a face that
otherwise stands exactly as it was painted, because Steel has nothing
to crumble into and nowhere near the lift to scatter.

A reader who runs this recipe sees all four rungs inside two minutes.
A reader who does not has to build the scene by hand.

## Digging and breaking

```odin
// Remove every cell in a disc that is soft enough. Returns the count.
sandbox_dig :: proc(sb: ^Sandbox, table: Material_Table, cx, cy: i32, radius: i32, power: u8) -> (removed: int)
```

A cell goes only if `hardness <= power`. The wizard digs at
`PLAYER_DIG_POWER`, which is 8.

| Material | Hardness | The wizard digs it |
| --- | --- | --- |
| Sand, Snow, Ash, Gunpowder | 1 | yes |
| Dirt, Ice, Gravel, Tnt | 2 | yes |
| Wood, Gold | 3 | yes |
| Coal | 4 | yes |
| Rock | 8 | yes, and it is the wall of every cave |
| Obsidian | 9 | no |
| Steel | 12 | no |
| Bedrock | 255 | no |

Rock at exactly the wizard's power is the point of the number. He can
dig the world he lives in and nothing else, so obsidian, steel and
bedrock are real walls to him and only a blast opens them.

## The plasma digger

```odin
// Cut a straight kerf from a point, and throw the cuttings back down
// it. Returns the count of cells removed.
sandbox_cut :: proc(sb: ^Sandbox, table: Material_Table, cx, cy: i32, dx, dy: f32, range, half_width: i32, power: u8) -> (removed: int)
```

`dx` and `dy` are a unit direction. `half_width` is the radius of the
swept disc, so the kerf is `2*half_width + 1` cells across at every
angle.

`sandbox_dig` above is a ball, and a ball clears whatever it is
dropped on. A beam marches out from one point in one direction and
which is the difference between a tool that acts near a man and a tool
he holds and points. The wizard now holds one; `docs/player.md`, "The
digger he holds", says what he points it with and how far it reaches.

**The beam is a ball swept along a line**, and not a line of cells
across the axis. A line of cells across a *diagonal* axis is a line
with holes in it: rounding a direction of 0.707 to whole cells puts
the span's cells corner to corner, and a kerf of cells that touch only
at their corners is a checkerboard the wizard cannot walk down and the
eye does not read as a cut at all. A disc has that problem at no
angle, and the cost of the overlap between one step's disc and the
next is a bounds test and a comparison on cells that are already air.

Three rules, and each one is a feel the ball dropped on a spot did not
have.

**The beam stops at what it cannot cut.** A cell harder than `power`
on the axis ends it there, so bedrock casts a shadow the way it does
for a blast. The axis is marched over the world as it stands, before
any cell is cut, or the march would clear the very wall that was to
stop it. Nothing past that end is cut either: the head of the last
disc would otherwise reach `half_width` through a thin wall and take
what stands behind it.

**What it removes it throws.** A cut cell becomes its crumbled form,
out of the same `crumbles_to` table a blast reads, and flies back down
the beam to land somewhere between `CUT_SPRAY_NEAR` and the cell it
came from. Back down the beam is the one direction the cut has
certainly opened, because every cell between the grain and the tool
was removed on the way out to it. This is the sawdust off a drill: it
comes back out of the hole and ordinary physics does the rest.

Two things a grain must be, or it is vapour instead:

- **Something that can fall.** A solid grain hangs in mid air where
  the throw left it. `Cell_Kind.Still` is exactly the set of cells
  that never move, and a crumbled form in that set is not thrown.
  Rock crumbles into gravel and gravel falls, so the wall of every
  cave sprays; coal has no crumbled form and so it does not.
- **Landing in air.** A grain that scatters out of the kerf into solid
  rock has nowhere to go. That is the falloff the scatter needs, and
  it costs one comparison.

**Most of it is vapour.** A grain is one cell and rock crumbles into
one cell of gravel, so a cut that threw all of it would fill its own
tunnel exactly as fast as it opened it, and the digger would move the
rock without ever removing any. `CUT_SPRAY_CHANCE` is 40 out of 255,
about one cut cell in six.

| Constant | Value | What it does |
| --- | --- | --- |
| `CUT_SPRAY_CHANCE` | 40 | out of 255: how much of a cut flies rather than vanishes |
| `CUT_SPRAY_NEAR` | 10 | cells nearest the tool that no grain lands in |
| `CUT_SPRAY_ACROSS` | 2 | cells either side of the beam a grain can scatter to |

`CUT_SPRAY_NEAR` is the room the man holding the beam stands in. A
grain thrown into his own body box is a grain the de-penetration
search at the top of `player_step` then has to lift him off, and
`src/player.odin` holds the two numbers together with an `#assert`.

Both numbers a throw needs come out of `sandbox_chance`, so the same
seed and the same tick throw the same grain to the same cell and a
replay still matches.

Two new command kinds ride the existing queue:

```odin
Command_Kind :: enum u8 { Noop, Spawn, Erase, Ignite, Explode, Dig, Move }
```

`radius` is the existing field. `material` carries `power` for
`Explode` and `Dig`, because it is the spare `u16` and a power is not
a material anywhere else. `Move` carries the aim in `x`, which is a
field it has no other use for: a `Move` names no place in the world,
and the aim has to reach `player_step` through the queue unchanged or
a replayed dig cuts a different tunnel than the one that was played.

## The wizard meets the sandbox

This is the gap `docs/player.md` names: "The sandbox and the player
never meet." Nothing in the gallery works until it is closed, because
a museum of physics that the visitor walks straight through is a
picture.

**One new type, and it is the whole join.**

```odin
// What the wizard collides with: the running sandbox where it covers
// him, and the generator everywhere else.
Terrain :: struct {
	world:   ^World,
	sandbox: ^Sandbox, // may be nil
}

terrain_cell_at :: proc(t: Terrain, wx, wy: i32) -> Cell
```

`player_step` and every `player_*` collision helper take a `Terrain`
instead of a `World`. The spawn scan takes one too, built as
`Terrain{world = world}` with no sandbox, because a wizard is placed
before any physics runs. Nothing else about the wizard changes: the same
numbers, the same one cell walk, the same climb.

`World` does **not** gain a sandbox pointer. `generate` is stateless
and answers any rectangle in any order, and that property is the
reason the world can be unbounded. A mutable pointer inside `World`
would end it.

Reading the sandbox is **cheaper** than reading the generator: one
array index against a biome lookup and five hashes. The join makes the
wizard faster where he stands, not slower.

**The sandbox is the whole map.** `sim_play_begin` opens it on
`world_rect`, which is every cell the biome map paints -- 8192 square
on the shipped map -- and `sim_follow_player` never opens another:
there is no square to walk out of. The light covers the same rectangle
(see `docs/lighting.md`), so nothing the runtime draws has an edge the
generator needed.

It used to be a 2048 cell square on a lattice of its own, and before
that the region. Both forgot: walk out of the square and back and the
hole you dug had closed, because the square was generated again. Both
stopped matter at their edge: a flow reached the border and met a
wall that was not in the world. Two tests hold the new shape --
`test_sim_play_begin_opens_the_sandbox_on_the_whole_world` and
`test_sim_follow_player_never_reopens_the_sandbox`.

```odin
sim_play_begin    :: proc(s: ^Sim)  // open the play sandbox on the whole map
sim_follow_player :: proc(s: ^Sim)  // move the light with him; the sandbox stays
sim_open_world    :: proc(s: ^Sim) -> Sim_Error
```

`sim_load` does not change. The MCP server and every test that opens a
sandbox by hand keep the sandbox they asked for. Only a caller that
says `sim_play_begin` gets the whole world.

### The whole world

What it costs was measured before anything was made quicker, because
the measurement says where the cost is, and it is not where a guess
would put it. `./bin/bench world=1` opens the play sandbox the game
plays on; `warm=N` settles it N ticks first, and `debug=2` prints the
awake map: one field a region, the biome's first letter and how many of
the region's 64 chunks the next tick will walk.

**Memory.** 64M cells at five bytes a cell -- the material, the
lifetime, the moved flag, the head -- is 320 MB. Opening it is 4.1 s
on this machine: the generate, the lifetime fill, the head fill and
the first tick over every chunk. That is a loading screen, and the
page (`docs/web.md`) starts at 192 MB and grows, so what a phone makes
of it is an open question at the end of this section.

**A tick, over time.** The world does not settle. It wakes up:

| Ticks settled first | A tick | Rows stepped | Cells loaded | `sandbox_react` calls |
| --- | --- | --- | --- | --- |
| 5 | 52 ms | 41k | 0.9M | 0.4M |
| 300 | 158 ms | 103k | 2.9M | 1.6M |
| 1000 | 278 ms | 151k | 5.1M | 3.0M |
| 3000 | 235 ms | | | |

It eases a little after a thousand ticks, as the first sand reaches
the floor of the oil, and no further: the columns keep coming.

For scale, the 2048 square the game used to play on costs 3.7 ms a
tick on the coal and 13.3 ms on the lake.

**Where the work is.** The awake map after 300 ticks, with the sky
rows and the deep rock rows that read all dots left out:

```
H  .H  4H  .H  3H  .H  2C 31C  7C  4C 22C  4C  2C  4C 15C  5C  2
C  4C  3C  4C  3C  1C  3C 21C  3C  5C 12C  3C  4C 11C 19C  8C  2
C  7C  4C  6C 26C  6C  7C  8C  4C  5C  7C  8C  3C 10C  3C  5C  5
C  8C 12C 13C 12C  9C  8C  8C 12C 11C 12C 14C 16C  6C 15C 10C 10
S 19S 20S 22S 24S 22S 19S 25S 21S 20S 17L 36L 35L 17L 38S 22S 21
S 12S 23S 24S 19S 15S 28S 22S 16S 16S 29L 38L 36L 26L 32S 18S 20
S 14S 16S 17S 21S 26S 27S 32S 18S 17S 15S 39S 35S 26S 22S 18S 23
O 12O 17O 13O 15O 29O 26O 31O 28O 16O 16O 29O 14O 25O 13O 11O 26
O  .O  8A  8A  .A  8O  7O  .O  .O  .O  .O  .O  .O  .O  .O  .O  .
O  .O  8A 43A 40A 43O  8O  .O  .O  .O  .O  .O  .O  .O  .O  .O  .
D  .D  1D  8D  8D  8D  1D  .D  .D  .D  .D  .D  .D  .V  .D  .D  .
```

The three rows of Sandcave, the Lake set into them, the Oilfield row
under them and the Acidpool are the world's cost. The coal is nearly
quiet: after 1000 ticks every Coalmine region reads under 10 but the
handful next to the cavemouth, and Coalmine alone on a 2048 square
settles to 3.1 ms. Each of the others alone, the same square, after
300 ticks:

| Biome, 2048 square | A tick | Chunks awake | Cells loaded | `sandbox_react` calls |
| --- | --- | --- | --- | --- |
| Coalmine | 3.1 ms | 99 | 75k | 36k |
| Sandcave | 10.4 ms | 255 | 208k | 82k |
| Oilfield | 22.6 ms | 133 | 380k | 301k |
| Lake | 28.0 ms | 348 | 546k | 290k |
| Acidpool | 34.6 ms | 185 | 567k | 451k |

Two numbers in that table say what a tick is made of. An awake row of
liquid costs about 60 ns a cell, nearly all of it the HOT pass:
water, oil and acid all have a row in the reaction table, so
`sandbox_react` walks the four sides of every cell of an awake wet
row. And a liquid region is awake in rows of 64 -- the dirty rect is
the chunk's -- so one grain sinking through oil keeps 64 cells of oil
paying for it on every row it passes.

**What keeps it awake.** Read at the picture, not the counts:
`./bin/shot x=-1536 y=512 w=512 h=1024 light=0 ticks=300` is a
Sandcave region standing on the Oilfield, at rest and after 300
ticks, and the zoom `./bin/shot x=-1320 y=-140 w=96 h=200 scale=6
ticks=300` is one tile edge in it.

1. **The tile seams had no crust.** A Sandcave tile is loose sand
   with a three cell face of rock wherever the mass meets a cave --
   `to_materials` in `tools/seed_tiles.py`. The face is drawn from
   how near a cell is to air, and a band cell may only look at its
   own four rows (the seam rule, at the head of that script), so a
   solid band over a cave in the tile's own interior stayed sand: a
   flat sand floor, no rock under it, and a cave beneath. It poured
   for the life of the world, and the same shape in the coal set was
   a flat dirt line that read as the lattice. The interior draws that
   face now: an open interior cell within `WALL` of a solid band cell
   is rock (`solid_band_near`). The band does not change, so the seam
   rule holds and `--check` still passes.
2. **A powder biome stands on a liquid biome.** The map puts three
   rows of Sandcave straight onto the Oilfield, and a Lake inside the
   Sandcave. Sand is heavier than oil and water, so every sand cell
   on the border sinks, in a column, to the floor of the oil three
   regions down, and the sand behind it follows. Nothing in a tile
   can fix that: the outermost row of a band is sand because the
   biome is, and what is past it belongs to another biome. It is a
   rule about the map, and it is the next rung, below.
3. **The acid pool eats its floor.** `Acid + Rock -> Air + Air` at 10
   in 255, and the Acidpool stands on Deep_Rock. It dissolves down
   into the rock for ever, and every row of it is a wet row.

### The order of work, measured

Each rung is one commit, and the bench numbers above are what it is
measured against. The checksum moves with the world on the first two
and the commit must say so.

1. **The seam crust.** Done, in the tile seeder, and both sets
   redrawn: only face cells changed, air to rock, and the reel still
   plays. Measured after it, on the 2048 square after 300 ticks:
   Sandcave 10.4 ms to 7.1, Coalmine 3.1 to 2.8. The world after 300
   ticks went from 158 ms to 150 and after 1000 from 278 to 255,
   which says the same thing the awake map says: the seams were a
   cost, and the map borders are the cost.
2. **The map rests every region on ground it keeps.** Done.
   `tools/seed_map.py` draws `data/biome_map.png` from a grid of
   letters and `--check` holds the file to four rules: every pixel a
   biome, no two touching regions that react, a liquid resting on and
   beside uniform solid regions only, a powder touching no liquid.
   The old map broke them 76 times. The lake is a rock basin now, the
   oil lies under a shelf of Deep_Rock, and the acid stands in
   Bedrock, a new uniform biome nothing in the reaction table
   touches. Measured: the world after 300 ticks went from 150 ms a
   tick to 35, and every liquid region reads a dot on the awake map.
   What is left awake is the Sandcave and the coal.
3. **The tiles are drawn through time.** Done, in the seeder, with
   the cave redrawn around it: every tile is one main tunnel now,
   mouth to mouth, 88 to 112 cells across and walked through two
   bends, with a branch to each other mouth and sometimes one that
   ends, and the noise cut lower so it reads as chambers off the way
   (`carve_trunk`; the header of `tools/seed_tiles.py`). What still
   moved in the coal after that was the rooms: masonry jointed in
   Gravel, a tank riveted in it, and lumps of it on a floor, and
   Gravel is a powder, so it poured out of the Well's wall and heaped
   on its shelves. The rooms are drawn of what stays -- Coal joints,
   Rock rubble. Measured after both, the world after 300 ticks is
   33 ms a tick and after 1000 31; Coalmine alone on the 2048
   square is 2.1 ms and Sandcave 1.9, where they were 3.7 and 10.4
   when this note began. What is left awake is
   dirt and sand settling into the wider caves.
4. **Then the step, on what is honestly awake.** Not before: the
   figures above are the cost of authoring, and a quicker step would
   only make the sand pour faster. When the map is right, the rung to
   take first is the one the per-biome table names: a wet row pays
   `sandbox_react` on every cell, and an awake row of one liquid with
   the same liquid on every side of every cell has no partner to find.
   A run of one material along the row can answer for all its cells
   at once, the way `sandbox_load_weights` already loads them. Measure
   it on `biome=Lake` and `biome=Oilfield`, where it is 60% of the tick.
5. **The wake is a row of 64.** A grain falling through a pond wakes
   its chunk row edge to edge. A narrower rect -- the chunk already
   keeps a bit a row; a `min_x, max_x` a row is 256 bytes a chunk --
   would keep a still pond still around one moving grain. Measure it
   on `biome=Lake` after rung 4, when it is what is left.
6. **The opening.** 4.1 s to open the world is a loading screen. It
   is four passes over 64M cells and any of them can go: the
   lifetime fill can be a table lookup in `generate`, the head fill
   only needs the wet regions, and the first tick's walk over every
   chunk is what `sandbox_mark_all` asks for. Measure each.
7. **The page.** 320 MB is more than a phone will give a tab. The
   rung is not a smaller world but a smaller cell: `lifetime` is an
   `i16` for every cell so that fire can count, and nearly every cell
   is rock with nothing to count. Whether the page keeps the whole
   map or a store of touched regions is a question to ask after the
   desktop tick is right, with its own measurement.

**A blast at the sandbox border stops at the border.** The border is
the edge of the map now, and past it is the off-map biome, one
material all the way out, so nothing that can move ever reaches it.

## The wizard on the queue

`docs/player.md` names the other missing rung: one `Move` command per
tick carrying a `Player_Input`, so a model can walk him the way a hand
does. The gallery needs it, because "walk through it and look" has to
be something a test can do.

The two spare bytes of `Input_Command` hold it, so the struct stays 32
bytes:

```odin
buttons: Player_Input, // what is held this tick
pressed: Player_Input, // what went down this tick, for the jump edge
```

The window keeps its direct path into `sim_step_player`, because held
keys through the queue's delay is input lag. Both paths call
`player_step`. There is still one implementation.

## The gallery

A hand painted region of rooms, one room per thing the sandbox does.

### `generator = image`

A third biome generator. A biome names a prefix, and the PNGs under it
are the region, one pixel to one world cell, in material colors, the
same way a tile is. The files are `<prefix>_<variant>.png`, exactly as
a wang set's are, and `variants` says how many there are.

```
[Gallery]
color     = 0xFF9B59B6
generator = image
image     = data/rooms/gallery      # data/rooms/gallery_0.png
fill_0    = Bedrock
```

A biome with more than one picture draws a different one in each of
its regions: `world_image_variant` hashes the region and the world
seed the same way `wang_tile_at` hashes a tile square, so a biome six
regions long comes out as six drawings of its set and another seed
lays out another six. The homelands are twelve pictures over six
regions; see `docs/homelands.md`.

Each image must be `cells_per_pixel` square, which is 512. The loader
says so plainly when it is not. `generate` treats it like a uniform
biome for the run limit, because the run cannot outlast the region
either way, and reads the cell from the image instead of the fill.

This is the same idea Noita uses for its hand made rooms, and it costs
one enum value, one loader field, one PNG reader that
`load_tile_png` already almost is, and one branch in `world_cell_at`.

The gallery goes at map pixel (8,3), which is world x 0 to 511 and y
-2560 to -2049. The entrance shaft goes in the top left of the image,
which is where `world_find_mouth` — the spawn rule the world had before
there were homelands — would have been most likely to find it.

That pixel is no longer on the ordinary map. A museum does not belong
in the middle of a coal seam, so the two galleries were moved into a
world of their own: `seed=0x1AB` opens the Laboratory, which is the
physics gallery and the alchemy gallery side by side at the bottom of
a cutting in the rock, and nothing else. See `docs/laboratory.md`.

**The gallery is now at map pixel (9,2) of that map, which is world x
512 to 1023 and y -3072 to -2561.** It moved because the light is
drawn a square 2048 cells on a side at a time and everything outside
that square is black, and the old rectangle lay against the edge of
one. The museum is laid in the middle of a square now, with lit rock
all round it. A room of the gallery is at world x `512 + 128 * col`, y
`-3072 + 128 * row`, counting rooms 1 to 16 in reading order.

The wizard lands on the roof of the museum, between its two doors.
`[Laboratory]` names that spawn the way `[Map]` names the village one.

### The rooms

Sixteen rooms in a four by four grid, which is 512 cells square and
exactly one region. Each room is 128 cells square **including** its
bedrock wall, so the space inside it is 120 by 120. A door at floor
level joins it to the room beside it, and a shaft at the end of each
row goes down to the next row.

Each room is fed by gravity and lit by the visitor. There is no
emitter material: a reservoir behind a wall with a hole in it is a
tap, and it is made of the physics the room is there to show.

| # | Room | What it shows | What starts it |
| --- | --- | --- | --- |
| 1 | Entrance and powder | Sand pours from a hopper and finds its angle | gravity |
| 2 | Water | Water falls down a stair and pools | gravity |
| 3 | Density | Oil, water and toxic sludge pour into one tank and settle in three layers | gravity |
| 4 | Gas | Steam and smoke climb and gather under the cap | gravity |
| 5 | Fuel | Fire runs the length of an oil trail | a seed of fire |
| 6 | Wood | A wooden frame burns, then falls as ash | a seed of fire |
| 7 | Quench | Water reaches a burning pool: the fire dies and steam rises | dig the plug |
| 8 | Lava | Water falls on lava: obsidian and steam | dig the plug |
| 9 | Ice | An ice block over lava becomes water; a snow bank melts | gravity |
| 10 | Acid | A pool of acid eats down through dirt, sand and rock, and stops at steel | gravity |
| 11 | Gunpowder | A pile goes off grain by grain and leaves a crater of gravel | ignite |
| 12 | Blast shadow | Tnt behind a bedrock pillar: the shadow of the pillar is unbroken rock | ignite |
| 13 | Digging | Eight strips: dirt, sand, coal, wood, rock, obsidian, steel, bedrock. He gets through five | dig |
| 14 | Collapse | A sand shelf on wooden struts. Burn the struts and the shelf comes down | a seed of fire |
| 15 | Boxes | Crates of wood, ice, sand, gunpowder and steel on plinths, each answering differently | anything |
| 16 | Gas hazard | A pocket of flammable gas lights all at once | dig the plug |

### The tool that draws it

`tools/seed_gallery.py`, in the shape of `tools/seed_tiles.py` and
`tools/seed_wizard.py`: plain Python, no libraries, the PNG written
with `struct` and `zlib`, a `--check` gate that holds the file on disk
to the rules.

```sh
tools/seed_gallery.py           # draws data/rooms/gallery_0.png
tools/seed_gallery.py --check   # holds the file to the rules
```

It reads `data/materials.txt` for the colors, so a material that
changes color is one run away from a gallery that agrees with it.

Three rules `--check` holds:

- Every pixel is a color some material in `data/materials.txt` claims.
- Every room joins the next one. A door is at least
  `PLAYER_BODY_H + 4` cells tall and `PLAYER_BODY_W + 4` wide, or the
  wizard cannot walk the museum.
- The outer border of the image is bedrock, apart from the entrance
  shaft in the top edge. A blast that reached the border would carry
  on into a neighbouring region, where nothing is simulated.

## Looking at it

`bin/shot` gains two arguments, so a room can be judged before and
after the physics runs:

```sh
./bin/shot seed=0x1AB biome=Gallery out=shots/gallery.png              # as painted
./bin/shot seed=0x1AB biome=Gallery ticks=600 out=shots/gallery600.png # after 10 seconds
./bin/shot seed=0x1AB x=512 y=-3072 w=128 h=128 scale=2 ticks=300 out=shots/room1.png
```

`seed=0x1AB` is the world the galleries are in, and without it
`biome=Gallery` says so and stops.

`ticks=N` opens a sandbox on exactly the rectangle the shot asks for,
runs N ticks, and draws that. The rectangle must fit
`SANDBOX_MAX_WIDTH` and `SANDBOX_MAX_HEIGHT`, so a shot that asks for
`ticks` on a larger area is refused and says why. `Shot` carries the sandbox the way it
already carries the player: on the struct, not as another argument.

The MCP server gains `player_move` and `player_status`, and
`enqueue_input` gains `explode`, `dig` and `move`. Every one of them
calls the procedure the window calls.

## The shape of the step

The step has to look at every cell of every dirty chunk, so its shape
is most of what a tick costs. It is a row at a time, in four passes,
and no pass carries an answer from one cell to the next.

| Pass | What it does |
| --- | --- |
| LOAD | reads the row, and the rows above and below it, into weights and kinds |
| HOT | the few cells with a lifetime, a reaction, or fire to spread |
| HEAD | on a row that holds liquid, how deep a body stands over each cell |
| INTENT | compares the three rows and writes the one step each cell wants |
| APPLY | moves the cells that want to move, and for a fluid going sideways looks along the row for the way on first |

**Weight is the whole move rule.** A cell carries one `u16`: air
weighs nothing, a wall weighs everything, and everything between
carries its density in 1/256ths. "Can this cell go there" is then one
integer comparison. Three things arrive as a wall and need no test of
their own: a solid, the world beyond the edge of the sandbox, and a
cell that already moved this tick.

**LOAD says what the other passes can skip.** It has the material in
hand, so it reports for free whether any cell of the row needs the hot
pass, and a row of rock and air pays nothing for it. INTENT reports
the same about movement, so a row that has settled pays nothing for
APPLY.

**INTENT is a vector pass.** `src/sandbox_step_simd.odin` asks the
same questions in the same order for sixteen cells at once.
`sandbox_intent_cell` is the same rules a cell at a time: it is the
reference the vector pass is read against, it runs on the cells at the
end of a row that do not fill a vector, and
`test_the_vector_intent_agrees_with_the_plain_one` holds the two to
the same answer over every material and every kind of neighbour.

Measured against the step this replaced, on the shipped world:

| What | Before | After |
| --- | --- | --- |
| the gallery, 512 square, 900 ticks | 0.46 ms a tick | 0.28 |
| a play sandbox on the mine, 2048 square | 7.1 ms a tick | 3.9 |
| one on the deeper caves and lake | 12.0 ms a tick | 5.2 |

Of that, the vector pass is worth about a sixth of the tick. The rest
came from the shape: no `Material` load in the inner loop, no branch
chain a cell, and two of the four passes skipped on most rows. A
settled pool also stops keeping its chunk awake, so there is less to
scan at all.

### Where the tick goes now

The vector pass moved INTENT off the top of the list, so the next
person to make the step quicker should not start there. Instructions
executed inside `sim_run`, on a 2048 square sandbox opened on four
biomes of the shipped world:

| Pass | Lake | Acidpool | Sandcave | Coalmine |
| --- | --- | --- | --- | --- |
| LOAD | 38% | 34% | 49% | 46% |
| HOT | 36% | 50% | 31% | 39% |
| INTENT | 10% | 9% | 13% | 12% |
| APPLY | 15% | 4% | 5% | 3% |

LOAD and HOT are about three quarters of the work between them.

**LOAD is now wide.** Two of the three rows it reads come through
`sandbox_load_weights`, and `src/sandbox_step_asm.odin` does that 32
cells at a time with an `asm` template: a material id is one byte, so
the material table is a `vpshufb` lookup. Measured against the build
before it, on a 2048 square sandbox: Sandcave -10%, Oilfield -10%,
Acidpool -10%, Lake -8%, Gallery -7%, Coalmine -5%, and every checksum
unchanged.

**HOT is not what it looks like.** The comment on that pass used to
say almost no cell needs it. That is true of a dry row and false of a
wet one: water, dirt, rock and sand all have a row in the reaction
table, so on the shipped world most cells of a wet row are live, and
what HOT spends is `sandbox_react` walking the four sides of each of
them. It is not a scan looking for a needle.

Two things were tried there and neither paid, so neither is in the
tree. Read this before trying them again:

- **A bit per cell saying which cells are hot**, written by LOAD and
  walked by HOT. It saves nothing when most cells are hot, and it
  costs a second pass over the row: a wash on the wet biomes and
  about 2% worse on the dry ones.
- **A bitset of reaction partners per material**, to replace the
  `n*n` table `sandbox_react` indexes four times a cell. Slower on
  every biome, by 5% to 12%. The dense `i16` table is already one
  load, and the multiply LLVM folds into the address beats a shift
  and a mask.

`bin/bench` is what measures a tick, and `--tool=callgrind` with
`--toggle-collect='game::sim_run'` is what splits it by pass. The four
pass procedures inline into one, so add `#force_no_inline` at the call
sites in `sandbox_step_row` before profiling, and take it out again.
This machine is noisy: take the best of five runs, and interleave the
two builds rather than running one after the other.

## The numbers

| Constant | Value | What it does |
| --- | --- | --- |
| `SANDBOX_MAX_WIDTH` | 8192 | the largest sandbox `sandbox_make` will build: the whole map |
| `PLAYER_DIG_POWER` | 8 | hardness he can remove; rock is exactly 8 |
| `PLAYER_DIG_RANGE` | 26 | cells the cut carries |
| `PLAYER_DIG_WIDTH` | 15 | cells across the kerf |
| `EXPLODE_MIN_RAYS` | 24 | rays in the smallest blast |
| `EXPLODE_RAYS_PER_CELL` | 6 | rays per cell of radius above that |
| `EXPLODE_BLAST_ODDS` | 150 | out of 255: how much of the inner blast catches |
| `BANG_MAX` | 16 | explosions the world remembers at once, for the light |
| `BLAST_LIFT` | 16 | sixteenths of energy per unit of density, in the lift formula |
| `BLAST_SCATTER` | 24 | lift at which matter flies clear |
| `BLAST_CRUMBLE` | 8 | lift at which matter breaks up and falls |
| `BLAST_CHIP` | 2 | lift at which a blast still bites a face |
| `BLAST_CHIP_ODDS` | 96 | out of 255: how much of a chipped face goes |
| `BLAST_FLING` | 2 | cells a scattered grain flies per unit of lift |
| `SANDBOX_LANES` | 16 | cells the vector intent pass answers at once |
| `SPREAD_DEFAULT` | 16 | how far a fluid looks along its row when its row in `data/materials.txt` names no `spread` |
| `SANDBOX_HEAD_MAX` | 127 | the deepest head a cell can hold, in the low seven bits of `sb.head` |
| `SANDBOX_HEAD_PRESS` | 0x80 | the eighth bit: more head stands here than this column explains |
| `spread` (Water) | 64 | and what water names, which is why a pond reads level |
| `spread` (Lava) | 3 | and what lava names, which is why a flow keeps its slope |
| `ROOM` (tools/museum.py) | 128 | cells along one edge of a room |
| `WALL` (tools/museum.py) | 4 | cells of bedrock between two rooms |

## The order of work

Each step compiles, passes `odin test src`, and can be looked at.

1. **The data.** The fifteen materials, `Material.force`, the
   `crumbles_to` table, the `[Reactions]` section and its loader. No
   change to the step. Tests: the table loads, a pair reads the same
   both ways round, every named material resolves, `Material` keeps
   its asserted size.
2. **The step.** Reactions, `sandbox_explode`, `sandbox_dig`,
   crumbling, detonation on ignite, the new command kinds. Tests: one
   per mechanic, plus the checksum still repeats.
3. **The cost.** Time a 512 by 512 step filled from a real region. If
   one tick costs more than 4 ms, add a dirty rectangle per 64 cell
   chunk and time it again. Measure before writing it.
4. **`generator = image`.** The enum value, the loader, the reader,
   the branch in `world_cell_at` and in `generate`. Tests: the fast
   generate still agrees with the naive one.
5. **The gallery.** `tools/seed_gallery.py`, the PNG, the biome, the
   map pixel.
6. **The join.** `Terrain`, the player against it,
   `sim_play_begin`, `sim_follow_player`, the window drawing the
   sandbox over the view, the `Move` command.
7. **The tools.** `ticks=` on the shot, the MCP tools, `docs/mcp.md`.
8. **The walk.** Shoot every room at rest and after it runs, look at
   the pictures, and fix what reads wrong. A test that walks the
   wizard from the entrance to the last room.

Step 8 is the one that decides whether any of this worked. The rest is
scaffolding for it.
