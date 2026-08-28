# The MCP server

The game runs as an MCP server, so a model can author the world and
play it. The server loads the same data the game window loads, and it
edits that world through the same procedures the mouse calls. The only
thing it does not have is a window.

## Build and connect

```sh
make mcp                 # builds bin/game-mcp
```

The repository holds a `.mcp.json`, so a client that reads that file
finds the server. To register it by hand with Claude Code:

```sh
claude mcp add the-game -- ./bin/game-mcp
```

The data paths are relative, so start the server from the repository
root. Other files can be named as arguments:
`game-mcp [materials-file] [biomes-file]`.

## The three parts

The tools follow the three things the game is made of.

| Part | What it decides | Tools |
| --- | --- | --- |
| The biome map | Which biome owns which region | `biome_map_view`, `biome_map_paint`, `biome_map_save` |
| The tile sets | What a biome is made of, tile by tile | `tile_open`, `tile_select`, `tile_view`, `tile_paint`, `tile_repair`, `tile_save` |
| The sandbox | What a rectangle of that world does next | `sandbox_open`, `enqueue_input`, `tick`, `observe`, `queue_peek` |
| The wizard | Where he stands, and driving him | `player_status`, `player_move` |

Three more tools read the tables: `world_status`, `list_materials`,
and `list_biomes`.

## One path, two hands

Every editor tool calls the same procedure the mouse handler calls.
`biome_map_paint` calls `editor_paint_pixel`, which is what a left
drag in the world editor calls. `tile_paint` calls
`tile_editor_paint_cell`, which is what a left drag in the tile editor
calls. `biome_map_save` calls `editor_save_map`, and it meets the same
gate: a map that falls into more than one connected piece does not
save, for a model as for a person. `tile_save` meets the other gate:
a set whose tiles disagree about a cell they share does not save
either.

So the two cannot drift apart. There is no second code path to keep in
step, and a rule added to the editor reaches both at once.

```
mouse ---> editor_paint_pixel ---> the biome map
MCP -----------^
```

The wizard follows the same rule (docs/player.md, "one path for a hand
and a model"). `player_move` calls `sim_step_player`, which is exactly
what the game window's fixed step calls and what a queued `move`
command applies. There is no path into his movement that only a model
can reach, or only a hand can.

## Painting with glyphs

Both editors take a picture as well as a rectangle. `list_materials`
and `list_biomes` print one glyph per entry, and `rows` stamps those
glyphs onto the map or the tile.

```
tile_paint  x=20 y=6 rows=["oooooooooooo",
                           "o..........o",
                           "o...GGGG...o",
                           "o..........o",
                           "oooooooooooo"]
```

A space leaves a cell alone, so a picture can be a stencil. On the
biome map a dot leaves a pixel alone as well, because a dot already
means an empty pixel there.

A biome glyph is the first letter of its name. Two biomes that start
with the same letter would clash, so the later one falls back to a
digit, counted over the biomes that had to fall back: `Sky` keeps `S`,
and `Sandcave` becomes `0`.

## The input queue

The sandbox is reached only through a queue, and the design comes from
old lockstep network code, where every machine had to reach the same
world from the same commands.

A command never changes the sandbox at the moment it arrives. It gets
an execution tick and waits in a ring of tick slots. At the start of
each tick the simulation takes one slot and applies the commands in it.

```
enqueue_input  ->  [ tick 12 ][ tick 13 ][ tick 14 ] ...  ring of 64 ticks
                                  |
tick           ->  drain tick 13, sort, apply, then step the sandbox
```

Three properties follow.

**Latency does not change the result.** A model that thinks for ten
seconds and a script that answers at once build the same world, because
a command carries a tick and not a time.

**The order is stable.** Commands on one tick run sorted by source and
then by sequence number. Two clients that send in a different order
still get the same world.

**A run repeats.** The sandbox is a function of the seed, the region it
was filled from, and the command list. The same three give the same
checksum, every time.

### Input delay

A command is not placed on the next tick. It is placed `input_delay`
ticks ahead, which defaults to 2. Old engines used the gap to let a
command reach every machine before the tick ran. Here the gap serves
the same purpose: a client can send several commands for one future
tick and know that all of them run together.

Send an exact `tick` to place a command on a chosen tick. A tick that
has already run is not dropped. The command moves to the next tick and
the reply reports it as late, so a slow client still has an effect and
still learns that it was slow.

### Limits

| Limit | Value | What happens at the edge |
| --- | --- | --- |
| Ticks the ring holds | 64 | A further tick is refused as `Too_Far` |
| Commands on one tick | 16 | A further command is refused as `Slot_Full` |
| Sources | 8 | A larger source number is refused |
| Input delay | 0 to 32 | A larger delay is clamped |
| Characters in one map | 20000 | The reply says to raise `sample` or `step` |

Nothing is dropped in silence. Every refusal reports the reason and
raises a counter that `world_status` prints.

## A full turn

The point of the merge is that an edit reaches the physics.

```
tile_open     biome=Coalmine             -> 32 tiles, 2 per signature
tile_select   edges=0110                 -> open on the east and the south
tile_paint    x=20 y=6 rows=[...]        -> every Coalmine region changes
sandbox_open  biome=Coalmine width=48 height=34
  -> sandbox 48x34 filled from world (-512,-2560), the first Coalmine region
     cells: Air 1502 Rock 96 Oil 30 Gold 4
enqueue_input kind=ignite x=22 y=6 radius=2
  -> runs on tick 2 (now 0, delay 2)
tick          count=40
observe
```

`sandbox_open` with no arguments reloads the same rectangle. That is
how any edit to the map or to a tile reaches a running sandbox.

## Reactions, explosions, digging, and the wizard

`enqueue_input` carries three more kinds beyond spawn, erase and
ignite, one per new mechanic in docs/physics.md:

- `explode` casts rays from the point, the way `sandbox_explode` does:
  a wall casts a shadow, and each cell a ray crosses costs its
  `hardness + 1` until the ray runs out of `power`.
- `dig` clears a disc of material soft enough for `power`; the wizard
  himself digs at power 8, which is exactly the hardness of rock.
- `move` drives the wizard for one tick: `buttons` is what is held,
  `pressed` is what went down fresh this tick, for the jump edge.
  `throw` is one of the buttons: held, it throws a pot of black
  powder along `aim`, which breaks into a small blast on the first
  thing it touches. `docs/pot.md` says how it flies and breaks.

`explode` and `dig` both need a `power` argument (0 to 255); there is
no default worth guessing at a blast or a dig strength from. `move`
needs neither `x`, `y`, nor `radius` — a wizard is not a point on the
map, he is `s.player` — so only `kind` is required on this tool now.

Reactions need no command at all. `Water + Fire -> Steam + Steam` and
the rest of the reaction table run on their own, one probe per cell
per tick, whenever two reacting materials end up beside each other; a
model does not enqueue a reaction, it enqueues the spawn or the ignite
that brings the two materials together.

## The wizard

`player_status` reports where he is: his position, what he is
standing on, his velocity, his jetpack fuel, and whether the play
sandbox is following him.

`player_move` drives him: give it `buttons` and a tick count, and it
calls `sim_step_player` that many times, the same procedure the game
window's fixed step calls and a queued `move` command applies
(docs/player.md, "one path for a hand and a model"). The first call
turns on following (`sim_play_begin`), which snaps the play sandbox to
the 2048 cell square he stands in so his feet rest on the running
physics rather than on a picture of it; later calls keep it following
him when he leaves that square on their own.

```
player_status
  -> wizard at (12.0,-2530.0), facing right
     on the ground, standing on Bedrock
     velocity (0.0,0.0) cells per second
     fuel 1.00 of 1.00
     the play sandbox is not following him yet; call player_move to start
player_move   buttons=["right","run"] ticks=120
  -> ran 120 ticks holding {Right, Run}
     wizard now at (155.3,-2530.0), on_ground true
     the play sandbox is at world (0,-2560)
```

## The tile sets

A biome with `generator = wang` owns a set of 512x512 tiles, and the
world lays them out on a lattice of tile squares, one cell of a tile
to one cell of world. Each tile carries a
color on each of its four sides. The lattice colors every edge from a
hash of its own position, and a square takes the tile whose four sides
match the four edges around it, so two tiles side by side always agree
about the edge they share and no rectangle of world has to be
generated before another one.

Two colors make a complete set 16 tiles. `variants` draws several
pictures of one set of edges, and the lattice picks between them, so
the same four edges do not always give the same tile.

`tile_select` names a tile by its edge colors, north east south west,
which is also the end of its file name:
`data/tiles/coalmine_0110_1.png`.

The cells within 4 of a side belong to the edge color rather than
to the tile. `tile_paint` writes a stroke there into every tile of the
set that carries that color, because that is the same seam seen from
another tile. `tile_view` says so before it prints the grid.

`tile_repair` is for files painted outside the editor. It makes every
shared cell agree again, and it never touches the middle of a tile.

## Reading the world

`observe` draws either source.

- `source=sandbox` reads the running physics in sandbox coordinates.
  `sample` puts several cells in one character.
- `source=world` reads the generator in world coordinates, at any
  `step`. This is what the game window shows, and it needs no sandbox.

The two lines above a map carry the tens and the units of the
coordinate. The number at the left of each row is the row itself.

## Checksums

Every `tick`, `sandbox_open`, and `world_status` reports a checksum of
the sandbox. Old network code sent the same number with each frame:
when two machines reported different numbers for the same tick, they
had drifted apart.

The same use works here. Record the seed, the region, and the commands,
replay them, and compare. A match proves the replay was exact.

## What the simulation covers

- A powder falls and forms a slope.
- A liquid falls, then spreads while the move helps it settle.
- A gas climbs.
- A denser material sinks through a lighter one that can flow, so sand
  sinks through water and smoke climbs out of it.
- A cell with a lifetime turns into the material named by `decays_to`.
  Fire leaves smoke, steam returns to water.
- Fire sets light material alight. The chance comes from
  `flammability`, and the result comes from `burns_to`. A flame holds
  still while fuel sits beside it, so fire runs along a trail of oil.
- Two materials that meet react, and both change: water quenches fire
  into steam, water on lava leaves obsidian and steam, acid eats rock
  and is used up itself, ice melts near fire. `[Reactions]` in
  `data/materials.txt` is the whole list; one probe per cell per tick
  is enough to make it happen without scanning every neighbour.
- An explosion casts rays from a point, the way `sandbox_explode`
  does. A wall stops the ray that meets it and casts a shadow; a
  corridor channels the blast on past it. A material with `force`
  above zero does not just burn: reaching it sets off a blast of its
  own, so a pile of gunpowder goes off grain by grain. The blast is a
  material too: the cell it goes off in, and the heart of the crater it
  opens, hold `Blast`, which lights the cave and decays to fire.
- A blast crumbles what it breaks open. A neighbour with `crumbles_to`
  set — rock into gravel, for instance — turns into that material and
  falls, instead of leaving a clean hole.
- A spell or a tool digs what it is strong enough for: `sandbox_dig`
  removes any cell whose `hardness` is no more than the digger's
  power. The wizard digs at power 8, which is exactly rock's hardness,
  so obsidian, steel and bedrock stay real walls to him.

All of it is in `data/materials.txt` and the `[Reactions]` section
inside it. A new material and a new reaction need no code.

A liquid finds its level only in part. A pool settles into one body and
holds its shape, but it can keep a slope and a few holes. A pressure
model would fix that and is not written yet.

See `docs/physics.md` for the numbers behind all of this — the
material table, the reaction table, and the gallery of rooms built to
show each mechanic on its own — and `docs/player.md` for the wizard
who now stands on it.
