# The player

A wizard stands at the top of the world beside a hole into the caves.
He walks, runs, jumps, and holds the jump key to fly on a jetpack that
fills again by itself. Nothing fights him and he casts nothing.

This note says how, and says what the phase leaves out.

## What the codebase decides for us

1. **`Sim` holds the game and knows nothing of a screen.** The MCP
   server and the game window both drive one. So the player is a field
   of `Sim`, and the picture of him is not.
2. **Fat structs, sized and asserted.** `Material` is 32 bytes with a
   `#assert`, and so is `Input_Command`. `Player` follows.
3. **A picture is the check.** `bin/shot` draws the world with no
   display. It learns to draw the wizard, so this phase can be judged
   from a terminal.

## The size of the wizard is not a choice

Two tiles that meet share the cells within `WANG_SEAM` of the border.
`tools/seed_tiles.py` forces a mouth 82 cells wide through that band,
and the lip of it wanders by up to 8 cells as the band goes deeper.
Only the cells clear through the whole band are a way out of the tile.

Measured over every shipped tile, that channel is **77 cells**, which
is nearly six of him.

A body taller than the channel fits every cave and no exit from one,
and the world reads as a lattice of sealed rooms. So:

| Thing | Cells | Why |
| --- | --- | --- |
| Frame | 24 x 32 | the picture, hat and staff and flame included |
| Body | 8 wide, 13 tall | what collides, with air either side in the channel |
| Body in frame | x 8, y 11 | so the art and the box cannot drift apart |
| Feet | frame row 23 | the position the player struct holds |

**The shape came off a reference. The size came off him.** A capture
of the Noita coal pits at one pixel per world cell is 51% open, and
neither the rock nor the air in it is islands in the other: it is
broad winding ground between large lobed masses. That is the shape the
tile sets draw, and it has not changed.

The same capture measures a mean unbroken run of open cells of 30
across and 21 down, and the sets were once drawn to those two numbers
as well. That is where the world came from that this note used to
describe: a channel of 32 cells against a body of 13. It measures
right and plays wrong. A wizard in it clears every passage and can
move in none of them, which is a tunnel and not a mine, and the eye
reads a body that large against the ground as a body too large for the
world.

So the grain of the noise was cut loose from the capture and set
against the body instead. A cave is now about 72 cells across and 52
down where it used to be 36 and 26, and the tiles grew from 256 cells
to 512 to hold several of them. Nothing about the wizard moved: he is
the same 13 cells he was, and the world around him is twice the size
in every direction.

`test_the_player_fits_the_world` is the test that holds both ends of
this. It measures the clear channel through the band of every tile
that carries an open edge, and fails if any is under `PLAYER_BODY_H +
2`, which is the body sealed in, or under `PLAYER_WORLD_CHANNEL`,
which is three of him and the point below which the world has shrunk
back to tunnels. Reseed the sets narrower and the test says so before
a player finds out.

## Collision reads Terrain

Collision no longer reads a bare `World`. `docs/physics.md`, "The
wizard meets the sandbox", adds `Terrain`: a `World` plus a `Sandbox`
pointer that may be `nil`. `terrain_cell_at` reads the sandbox where it
covers the cell asked for and the generator everywhere else, so the
same collision code walks on a picture, on the running physics, or on
both at once depending only on which `Terrain` it was handed.

```odin
// Whether a world cell stops the player.
player_solid_at :: proc(t: Terrain, x, y: i32) -> bool
```

Solid is `state == .Solid || state == .Powder`. Rock, Gold, Dirt and
Sand hold him up. Air, Water, Oil, Acid, Lava, Fire, Smoke and Steam do
not.

The generator's own answer, `world_cell_at`, is not cheap: it costs a
biome lookup and five splitmix64 hashes, and `worldgen.odin` says so
where it explains why generation works in runs. A sandbox read is one
bounds check and one array index, so wherever the sandbox covers him
`Terrain` is cheaper to ask than the generator alone, not more
expensive. Either way, a move tests **only the leading edge** of the
body: 13 cells for a sideways move and 8 for a vertical one, never the
whole 104 cell box.

**What this costs, said plainly:** he only falls with ground that is
in a `Sandbox`. `sim_play_begin` opens one on the 2048 cell square he
stands in and slides it with him when he leaves it, and only a caller
that asks for that gets it: the MCP server and most tests still build a
`Terrain` with `sandbox = nil`, and there the world is exactly the
static picture it always was.

## A fixed step driven by held buttons

```odin
Player_Button :: enum u8 { Left, Right, Jump, Run, Dig }
Player_Input  :: bit_set[Player_Button; u8]

player_step :: proc(p: ^Player, t: Terrain, held: Player_Input, jump_pressed: bool)
```

The step is a whole tick at `PLAYER_TICK_HZ` (60). The window keeps an
accumulator and calls it a whole number of times per frame, because
`SetTargetFPS` is a target and a dropped frame must not slow the
wizard down.

Integration is semi-implicit Euler, **velocity first and then
position**, because the two orders give jump heights 2.5 cells apart
and the order has to be written down.

`jump_pressed` is the edge and `Jump` in `held` is the level. A press
jumps; holding the same key in the air runs the jetpack. Without that
split there is no jump at all, because a held key would always fly.

**The window does not put his held keys on the `Input_Queue`.** The
queue holds a command for a few ticks to hide latency between
machines, and held movement keys through a delay is input lag, so the
window still calls `sim_step_player` directly rather than pretending
otherwise.

A `Move` command now rides the queue beside it (`docs/physics.md`,
"The wizard on the queue"), carrying a `Player_Input` for what is held
and a second, `pressed`, for the jump edge, in the two bytes
`Input_Command` had left spare. `sim_apply` routes it into the same
`player_step` the window calls, so a caller willing to pay the queue's
delay gets a replayable, deterministic path to move him — `Sim` is a
function of seed, region and commands alone again, for that caller.
One thing is still missing: there is no MCP tool built on top of
`Move` yet, so "one path for a hand and a model" does not fully cover
him until `docs/physics.md` step 7 adds one.

## The numbers

Cells and seconds, because that is what the world is measured in.

| Constant | Value | What it does |
| --- | --- | --- |
| `PLAYER_TICK_HZ` | 60 | steps per second |
| `PLAYER_BODY_W` | 8 | cells |
| `PLAYER_BODY_H` | 13 | cells |
| `PLAYER_WALK_SPEED` | 42 | cells per second |
| `PLAYER_RUN_SPEED` | 74 | cells per second, holding Shift |
| `PLAYER_GROUND_ACCEL` | 320 | how fast he reaches that speed |
| `PLAYER_AIR_ACCEL` | 140 | less control in the air |
| `PLAYER_GROUND_FRICTION` | 420 | how fast he stops |
| `PLAYER_AIR_DRAG` | 30 | he keeps his speed in the air |
| `PLAYER_GRAVITY` | 430 | cells per second per second |
| `PLAYER_JUMP_SPEED` | 155 | the launch: 26.7 cells at this tick rate |
| `PLAYER_MAX_FALL` | 420 | terminal speed |
| `PLAYER_JET_ACCEL` | 880 | up, against gravity, so 450 net |
| `PLAYER_JET_MAX_RISE` | 130 | the jetpack does not accelerate for ever |
| `PLAYER_JET_DELAY_TICKS` | 6 | after a jump press, before thrust starts |
| `PLAYER_FUEL_MAX` | 1.0 | one tank |
| `PLAYER_JET_DRAIN` | 0.5 | tanks per second under thrust, so 2.0 seconds |
| `PLAYER_FUEL_ON_GROUND` | 1.4 | tanks per second standing, so 0.71 seconds |
| `PLAYER_FUEL_IN_AIR` | 0.22 | tanks per second falling, and **not** under thrust |
| `PLAYER_WORLD_CHANNEL` | 39 | 3 x `PLAYER_BODY_H`: the channel the world owes him |
| `PLAYER_COYOTE_TICKS` | 5 | ticks after a ledge where a jump still works |
| `PLAYER_CLIMB` | 3 | cells he walks up without jumping |
| `PLAYER_DIG_OUT` | 24 | cells he searches upward when buried |
| `SPAWN_MOUTH_DEPTH` | 10 | cells a column must be clear to count as a way in |
| `SPAWN_CLEARANCE` | 12 | cells from the mouth edge to the spawn |
| `SPAWN_SEARCH_RANGE` | 4096 | cells either side of x 0 that the scan covers |

Fuel does not fill under thrust. A 2.0 second burn climbs 241 cells,
which is more than a screen height. Standing fills the tank in 0.71
seconds, and a long fall trickles back enough for a landing burn.

`PLAYER_CLIMB` is 3, not 5. The seeder settles the edge of a cave with
a 3x3 majority, which moves a wall by a cell or two, so 3 walks over
the roughness the caves actually have and a taller ledge stays a jump.
The tiles grew from 64 cells to 256 and then to 512, and this did not
have to follow either time: the smoothing works a cell at a time
whatever the tile size is, so a bigger cave has a finer wall, not a
coarser one. The rock face the seeder draws at a cave edge is 3 cells
for the same reason.

## Movement resolves one cell at a time

```
if the body overlaps solid at the start of a tick:
    search up to PLAYER_DIG_OUT cells upward for a clear body position
    and move there; if none is clear, let this tick move freely

for axis in (x, y):
    remaining = velocity[axis] / PLAYER_TICK_HZ
    while remaining is not spent:
        d = clamp(remaining, -1, 1)
        if the leading edge at position + d is clear:
            position[axis] += d
        else if axis is x and on_ground and a climb of up to
                PLAYER_CLIMB clears BOTH the raised body and its ceiling:
            take the climb, then drop back to the floor
        else:
            velocity[axis] = 0     # this axis only
            break
        remaining -= d
```

The one cell walk is not about tunnelling. It cannot tunnel at these
speeds: the largest step is 7 cells against a 13 cell body, so the
volumes before and after a move always overlap. It is there because it
resolves **first contact** rather than an arbitrary end position, and
because the climb needs the position part way through.

Three rules the pseudocode above makes explicit, because each one is a
bug when it is left implicit:

- Only the velocity of **this** axis is cleared. Hitting a wall must
  not cancel a fall.
- A climb tests the raised body **and** the ceiling above it. In a 16
  cell channel a climb into rock is the common case, not the corner.
- After a climb he drops back to the floor, or a ledge that ends leaves
  him walking on air in `PLAYER_CLIMB` sized stairs.

The body occupies cells `[floor(x - W/2), floor(x + W/2))` across and
`[floor(y) - H, floor(y))` down, so `y` is the floor his feet rest on
and `on_ground` is a clear test of the row at `floor(y)`.

**De-penetration is not hypothetical.** The editor regenerates the
world on every paint stroke, so a player can be inside rock through no
fault of his own. Without the first rule above he freezes there for
ever.

## He spawns beside a hole, not in it

The starter map puts Sky in rows 0 to 2 and Coalmine in rows 3 to 6.
With `origin_pixel = 8 8` and `cells_per_pixel = 512` the roof of the
caves is world y -2560, and the sky above it is open air.

```odin
world_find_spawn :: proc(world: World) -> (x, y: i32, found: bool)
```

1. Find the first map row a tiled biome owns. Its top edge is the
   surface.
2. Scan x across `SPAWN_SEARCH_RANGE` either side of zero, clamped to
   the painted map. A **mouth** is a column clear for
   `SPAWN_MOUTH_DEPTH` cells below the surface.
3. Step `SPAWN_CLEARANCE` cells out from the mouth to a column with
   solid ground at the surface and a clear body box above it.
4. Return that column, feet on the ground.

`SPAWN_CLEARANCE` is 12, not 1. The nearest solid column to a mouth is
the lip of the hole, and an 8 cell body placed there hangs half over
the edge and falls in on the first tick.

If nothing is found, the fallback stands him in the open sky above the
first tiled region **and tests that place for solid** before using it.
A repainted map must not spawn him inside rock.

## A view the wizard is visible in

`step` is world cells per texel and stops at 1. `zoom` is screen pixels
per texel and joins it, and only one of the two is ever above 1:

```
    ... 4     2     1     1     1      step
        1     1     1     2     4      zoom
      <- out                   in ->
```

`zoom` is 1, 2 or 4 and never 3, because 1280 and 720 divide by 1, 2
and 4 exactly. A non-integer scale in a pixel game leaves an uneven
grid. Play starts at `zoom = 4`: 320 by 180 cells on screen, five tiles
across, and a wizard 76 pixels tall.

The buffers are allocated once at full size. At zoom n the generator
fills `WINDOW_W/n by WINDOW_H/n` texels, and because `generate` writes
rows of exactly `view.w`, the first `w*h` entries **are** the tightly
packed rectangle `UpdateTextureRec` wants. The colour conversion loop
is bounded to `w*h` as well, or the zoom saves nothing on the CPU.

Four call sites read the visible extent as `WINDOW_* * app.step`, which
is only true at zoom 1. All four go through one procedure:

```odin
app_view_cells :: proc(app: ^App) -> (w, h: i32)
```

| Site | What breaks without it |
| --- | --- |
| `editor.odin` camera box | the box on the map is drawn zoom times too large |
| `editor.odin` look at pixel | `M` lands zoom times off centre |
| `main.odin` HUD | it names the wrong cell and the wrong biome |
| `tile_editor.odin` open and close | it forces `step = 1` for one painted cell per pixel, and must force `zoom = 1` the same way |

The camera follows the player with a dead zone and marks the view dirty
only when `cam_x` or `cam_y` actually change, so a standing player does
not regenerate the screen sixty times a second.

## The sprite

`tools/seed_wizard.py` draws `data/sprites/wizard.png`, the way
`tools/seed_tiles.py` draws the tile sets: plain Python, no libraries,
the PNG written with `struct` and `zlib`, and a `--check` gate.

A row is an animation and a column is a frame. The sheet is 6 by 6 and
holds 24 frames, so the row lengths are data both the tool and the game
read:

| Row | Animation | Frames |
| --- | --- | --- |
| 0 | Idle | 4 |
| 1 | Walk | 6 |
| 2 | Run | 6 |
| 3 | Rise | 2 |
| 4 | Fall | 2 |
| 5 | Jet | 4 |

Every frame faces right, and the body box is centred across the frame,
so facing left is the same frame drawn mirrored.

`Sprite_Sheet` holds RGBA and a grid. Unlike a tile PNG it does **not**
match colours against the material table: alpha 0 is transparent and
that is all. It is loaded through `rl.LoadImage` and
`rl.LoadImageColors`, which need no window, and it has a
`destroy_sprite_sheet` like every other allocation in this codebase.

## The order of work

Each step compiles, passes `odin test src`, and can be looked at.

1. `tools/seed_wizard.py` and the sheet. **Done.**
2. `src/player.odin`: the struct, the numbers, the collision walk, the
   step, the spawn, and the tests. No picture and no window. This is
   the part that has to be right.
3. `src/sprite.odin`: load the sheet, pick a frame, free it, test both.
4. `src/shot.odin` and `cmd/shot/main.odin`: `player=1`, which also
   aims the view at him. `./bin/shot player=1` then shows the wizard at
   the cave mouth from a terminal. **This is the check on 2 and 3, and
   it comes before the window on purpose.**
5. `src/sim.odin`, `src/main.odin`, `src/editor.odin`,
   `src/tile_editor.odin`: hold the player, spawn him, the play camera,
   the zoom, the input, the draw, the HUD.
6. `README.md` and `AGENTS.md`.

No Makefile change: `SOURCES := $(wildcard src/*.odin)` already covers
a new file, and both `cmd/` targets depend on it.

## Controls

| Key | Action |
| --- | --- |
| `A` `D` or `LEFT` `RIGHT` | Walk |
| `SHIFT` | Run |
| `SPACE` or `W` or `UP` | Jump; hold in the air to fly |
| `E` or left mouse button | Dig, in the direction he faces |
| `TAB` | The world editor, where the camera pans freely again |
| Wheel, `-`, `=` | Zoom |

## What this phase leaves out

No health, damage, combat, wands, spells, inventory, sound, or
networked movement.

Digging is built (`docs/physics.md`, "Digging and breaking"), but only
where a `Sandbox` is under him: `PLAYER_DIG_POWER` and
`PLAYER_DIG_RADIUS` live in `src/player.odin` beside the rest of his
numbers, because rock is hardness 8 there on purpose, matching the
world he digs.

Two things this note used to name here are closed, and one is not:

- **The world moves under him, where a `Sandbox` is following him.**
  `sim_play_begin` opens one on the square he stands in, sixteen
  regions of it, and the window steps it every tick alongside him; dig
  a hole in it and the sand above falls.
  See `docs/physics.md`, "The wizard meets the sandbox".
- **The sandbox and the player meet, the same way.** A caller that
  never asks to follow — the MCP server, most tests that open a
  sandbox of their own — still gets the old, static `Terrain`, so for
  them nothing here has changed.
- **Liquids are not solid**, still. Lake, Oilfield, Acidpool and Magma
  are free fall, which is a drop of some 3500 cells from the caves to
  the deep rock, and nothing above touches that.
