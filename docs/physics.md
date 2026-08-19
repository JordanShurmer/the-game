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
| Liquid falls, pools, and layers by density | Falling and pooling were done. Layering was not: see "The rise rule" below |
| Gas climbs and gathers under a ceiling | Already done |
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

Four things Noita does that we do **not** build in this phase. Each
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
- **No pressure, and no sideways exchange between liquids.** A pool
  settles into one body and holds its shape, but it can keep a slope.
  Noita does not equalise across a U bend either, so that part is a
  match with the reference and not a debt. The second half is a real
  limit: a liquid swaps with a lighter one below it and never with one
  beside it, so two liquids poured into a wide tank settle with no
  cell resting on anything lighter and still read as a diagonal smear
  rather than as layers. The density room is a narrow column for that
  reason. The rung that would lift it is a sideways swap gated on
  density, which has to be written so that a settled pool of one
  liquid does not jitter for ever.
- **No temperature field.** A number per cell for heat would cost as
  much memory as the cells and buy behaviour that the reaction table
  already gives. Fire, melting, freezing and boiling are all pairs of
  materials that meet.

## What the codebase decides for us

1. **A new material and a new reaction need no code.**
   `docs/mcp.md` already makes that promise. Everything below holds it.
   Reactions are rows in `data/materials.txt`, not a switch in Odin.
2. **`Material` is 32 bytes and the `#assert` says so.** It has two
   bytes of tail padding today. One of them becomes `explosive`. The
   struct does not grow.
3. **Hot fields in the struct, cold fields in parallel tables.**
   `crumbles_to` is read only when a blast lands, so it is a cold
   table beside `decays_to` and `burns_to`.
4. **A run repeats.** The sandbox is a function of the seed, the
   region, and the command list. Reactions draw from `sandbox_rand`.
   Explosions draw from nothing at all: the rays are fixed angles.
   `sandbox_checksum` stays the whole test for both.
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
// 12 bytes, and the #assert holds it there.
Reaction :: struct {
	a, b:   u16, // what meets
	c, d:   u16, // what it becomes
	chance: u8,  // out of 255, per probe
	_pad:   [3]u8,
}
#assert(size_of(Reaction) == 12)
```

The table carries three things:

```odin
reactions: []Reaction, // every row, both ways round
reaction_at: []i16,    // n*n; the row for a pair, or -1
reacts: []bool,        // n; whether this material is in any row at all
```

`reaction_at` is a dense square of `i16`, indexed `a*n + b`. With the
27 materials the game ships that is 729 entries, or 1458 bytes. A
table of 200 materials would cost 80 KB, which is the bound worth
knowing and far past what this game needs.

`reacts` is the gate that keeps the step cheap. Air is in no row, so
the common cell pays one byte of lookup and nothing else.

**One probe per cell per tick.** A cell that can react picks one of
its four sides from `sandbox_rand` and tests that pair. It does not
test all four. Four probes cost four times as much and only make a
reaction that already happens happen sooner. A chance of 255 on one
of four sides still resolves in a few ticks, which at 60 Hz is a
frame or two.

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
4. A cell the ray pays for becomes `Air`, or `Fire` when it lies in
   the inner third of the radius. The inner third is what lights the
   fuel in the room.
5. Each cell that is cleared crumbles its four neighbours: a
   neighbour whose `crumbles_to` is set becomes that material. Rock
   becomes gravel and rains down.

So `power` reads as "how many cells of empty air this blast crosses".
A `power` of 64 crosses 64 cells of air or 7 cells of rock.

**A material with `explosive` above zero detonates instead of
burning.** When `sandbox_ignite` or `sandbox_spread_fire` reaches such
a cell, the cell becomes Air and a blast starts there with
`power = explosive` and `radius = explosive`.

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
again this tick. The fire the blast leaves reaches the next grain on
the next tick, and that grain detonates in its own `sandbox_step_cell`.
Without this rule one grain of gunpowder recurses through a whole pile
inside one call and overflows the stack. With it, a pile takes a few
ticks to go off, which is also what a chain should look like.

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

Two new command kinds ride the existing queue:

```odin
Command_Kind :: enum u8 { Noop, Spawn, Erase, Ignite, Explode, Dig, Move }
```

`radius` is the existing field. `material` carries `power` for
`Explode` and `Dig`, because it is the spare `u16` and a power is not
a material anywhere else.

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
	world:   World,
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

**The sandbox is the region he is in.** One region is 512 cells
square, which is inside `SANDBOX_MAX_WIDTH`. When he crosses a region
border, the sandbox refills from the generator at the new region.

```odin
sim_play_begin  :: proc(s: ^Sim)  // open the play sandbox on his region
sim_follow_player :: proc(s: ^Sim) // refill it when he leaves that region
```

`sim_load` does not change. The MCP server and every test that opens a
sandbox by hand keep the sandbox they asked for. Only a caller that
says `sim_play_begin` gets the following one.

**What this costs, said plainly.** A region you walk out of and back
into is generated again, so the hole you dug in it closes. The rung
that fixes it is a store of the regions that have been touched, keyed
by region coordinate, written when the sandbox slides off one. The
gallery is one region, so nothing in this note shows the seam.

**A blast at a region border stops at the border.** The sandbox ends
there and the generator behind it does not move. Bedrock at the edge
of the gallery hides it.

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

A third biome generator. A biome names one PNG, and that PNG is the
region, one pixel to one world cell, in material colors, the same way
a tile is.

```
[Gallery]
color     = 0xFF9B59B6
generator = image
image     = data/rooms/gallery.png
fill_0    = Bedrock
```

The image must be `cells_per_pixel` square, which is 512. The loader
says so plainly when it is not. `generate` treats it like a uniform
biome for the run limit, because the run cannot outlast the region
either way, and reads the cell from the image instead of the fill.

This is the same idea Noita uses for its hand made rooms, and it costs
one enum value, one loader field, one PNG reader that
`load_tile_png` already almost is, and one branch in `world_cell_at`.

The gallery goes at map pixel (8,3), which is world x 0 to 511 and y
-2560 to -2049. That is the region the wizard spawns above, and the
entrance shaft goes in the top left of the image for a reason:
`world_find_mouth` starts its search at world x 0 and grows outward,
so a shaft near x 0 is the mouth it is most likely to find, and he
starts on the roof of the museum beside its door.

He is not made to start there. A Coalmine mouth a few cells to the
left of zero can win the search, and that is not a failure: the
surface above the gallery is bedrock, which is a floor, so he walks or
flies along it to the shaft. Step 8 shoots the picture and says where
he actually lands.

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
tools/seed_gallery.py           # draws data/rooms/gallery.png
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
./bin/shot biome=Gallery out=shots/gallery.png              # as painted
./bin/shot biome=Gallery ticks=600 out=shots/gallery600.png # after 10 seconds
./bin/shot biome=Gallery x=0 y=-2560 w=128 h=128 scale=2 ticks=300 out=shots/room1.png
```

`ticks=N` opens a sandbox on exactly the rectangle the shot asks for,
runs N ticks, and draws that. The rectangle must fit
`SANDBOX_MAX_WIDTH` and `SANDBOX_MAX_HEIGHT`, so a shot that asks for
`ticks` on a larger area is refused and says why. `Shot` carries the sandbox the way it
already carries the player: on the struct, not as another argument.

The MCP server gains `player_move` and `player_status`, and
`enqueue_input` gains `explode`, `dig` and `move`. Every one of them
calls the procedure the window calls.

## The numbers

| Constant | Value | What it does |
| --- | --- | --- |
| `SANDBOX_PLAY_SIZE` | 512 | the play sandbox is one region |
| `PLAYER_DIG_POWER` | 8 | hardness he can remove; rock is exactly 8 |
| `PLAYER_DIG_RADIUS` | 5 | cells |
| `EXPLODE_MIN_RAYS` | 24 | rays in the smallest blast |
| `EXPLODE_RAYS_PER_CELL` | 6 | rays per cell of radius above that |
| `REACT_PROBES` | 1 | sides a cell tests per tick |
| `GALLERY_ROOM` | 128 | cells along one edge of a room |
| `GALLERY_WALL` | 4 | cells of bedrock between two rooms |

## The order of work

Each step compiles, passes `odin test src`, and can be looked at.

1. **The data.** The fifteen materials, `Material.explosive`, the
   `crumbles_to` table, the `[Reactions]` section and its loader. No
   change to the step. Tests: the table loads, a pair reads the same
   both ways round, every named material resolves, `Material` is
   still 32 bytes.
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
