package game

import "core:math"
import "core:testing"

/*
The player: a wizard who walks, runs, jumps, and holds the jump key to
fly a jetpack that fills again on its own. He is a field of Sim, not a
field of the window, because both the MCP server and the game window
drive one Sim and neither owns the other; docs/player.md calls this
out as a decision the rest of the codebase already made for us.

He collides with Terrain, not with World directly. Terrain reads the
running Sandbox where it covers him and the generator everywhere
else, which is the join docs/physics.md calls "the whole point of the
gallery": dig a hole in the sandbox under his feet and he falls in
it, because his collision and the physics now read the same cells.
See terrain_cell_at below for the whole of that join; it is two
fields and one proc, on purpose.

Because the generator is not cheap to ask, collision asks it as
little as it can. Resolving a tick's move one cell at a time only ever
tests the leading edge of the body: PLAYER_BODY_H cells for a sideways
step, PLAYER_BODY_W for a vertical one, never the full 104 cell box.
The full box is still tested, but only twice: once to place a fresh
spawn, and once at the start of every tick, because the world editor
regenerates the world under a running game on every paint stroke and a
player can wake up inside rock through no fault of his own.

His size is not a free choice either. Two tiles of a Wang set share a
band WANG_SEAM cells wide along the edge where they meet, and every
mouth the world carves narrows to whatever clear channel survives that
whole band on every side at once. The shipped tile sets hold that
channel to 16 cells. A body taller than that fits every cave and
leaves none of them, which is why the body is 13 cells tall and 8
wide, with a cell of air either side of it in the narrowest tunnel.
test_the_player_fits_the_world is the guard on that number: it
measures the real channel in the shipped tiles and fails before a
wizard finds himself sealed in one.
*/

// ------------------------------------------------------------
// Input
// ------------------------------------------------------------

Player_Button :: enum u8 {
	Left,
	Right,
	Jump,
	Run,
	Dig, // remove terrain in front of him; see PLAYER_DIG_POWER below
}

Player_Input :: bit_set[Player_Button; u8]

// ------------------------------------------------------------
// The numbers
//
// Cells and seconds, because that is what the world is measured in.
// See docs/player.md for what each one does and why it is this value;
// the names and values here must match that table exactly, because it
// is the one place both a reader and a future editor go to check them.
// The digging constants at the end of this block are the one
// exception: PLAYER_DIG_POWER and PLAYER_DIG_RADIUS are documented in
// docs/physics.md's own numbers table instead, and that is the place
// to check them against. PLAYER_DIG_REACH is new here, with no table
// of its own; the comment above it says what it does.
// ------------------------------------------------------------

PLAYER_TICK_HZ :: 60 // steps per second

PLAYER_BODY_W :: 8  // cells
PLAYER_BODY_H :: 13 // cells

PLAYER_WALK_SPEED       :: 42  // cells per second
PLAYER_RUN_SPEED        :: 74  // cells per second, holding Shift
PLAYER_GROUND_ACCEL     :: 320 // how fast he reaches that speed
PLAYER_AIR_ACCEL        :: 140 // less control in the air
PLAYER_GROUND_FRICTION  :: 420 // how fast he stops
PLAYER_AIR_DRAG         :: 30  // he keeps his speed in the air

PLAYER_GRAVITY    :: 430 // cells per second per second
PLAYER_JUMP_SPEED :: 155 // the launch: 26.7 cells at this tick rate
PLAYER_MAX_FALL   :: 420 // terminal speed

PLAYER_JET_ACCEL       :: 880 // up, against gravity, so 450 net
PLAYER_JET_MAX_RISE    :: 130 // the jetpack does not accelerate for ever
PLAYER_JET_DELAY_TICKS :: 6   // after a jump press, before thrust starts

PLAYER_FUEL_MAX        :: 1.0  // one tank
PLAYER_JET_DRAIN       :: 0.5  // tanks per second under thrust, so 2.0 seconds
PLAYER_FUEL_ON_GROUND  :: 1.4  // tanks per second standing, so 0.71 seconds
PLAYER_FUEL_IN_AIR     :: 0.22 // tanks per second falling, and not under thrust

// The channel the world owes him, as against the one he fits through.
//
// A body of 13 passes a channel of 15, and a world drawn to 15 is a
// world of tunnels: he clears it and cannot move in it, which is what
// the sets drew while they were sized off the mean run of the
// reference capture (32 cells measured, under two of him).
//
// Three of him is the floor, not the aim. The shipped sets measure 77
// cells at their narrowest, which is nearly six; this is set well
// below that so an ordinary reseed has room to differ, and well above
// what he fits through so a reseed that puts the tunnels back fails
// here rather than in the hands of a player.
PLAYER_WORLD_CHANNEL :: 3 * PLAYER_BODY_H // cells

PLAYER_COYOTE_TICKS :: 5  // ticks after a ledge where a jump still works
PLAYER_CLIMB        :: 3  // cells he walks up without jumping
PLAYER_DIG_OUT      :: 24 // cells he searches upward when buried

SPAWN_MOUTH_DEPTH  :: 10   // cells a column must be clear to count as a way in
SPAWN_CLEARANCE    :: 12   // cells from the mouth edge to the spawn
SPAWN_SEARCH_RANGE :: 4096 // cells either side of x 0 that the scan covers

// Digging. See docs/physics.md, "Digging and breaking": rock is
// hardness 8, exactly PLAYER_DIG_POWER, so he digs the world he lives
// in and nothing harder; obsidian, steel and bedrock stay real walls
// to him. This is not PLAYER_DIG_OUT above, which is de-penetration
// searching for open air, not a tool cutting into solid ground.
PLAYER_DIG_POWER  :: 8 // hardness he can remove
PLAYER_DIG_RADIUS :: 5 // cells

// Cells from his center to the dig point, in the direction he faces:
// a few cells past his chest, clear of his own body, so he does not
// dig the ground he is standing in.
PLAYER_DIG_REACH :: 6

// ------------------------------------------------------------
// Motion, for the sprite sheet
// ------------------------------------------------------------

/*
Which animation row is playing.

THIS ENUM IS A CONTRACT. src/sprite.odin reads it to pick a row of
data/sprites/wizard.png, and the order matches the rows of that sheet
one for one: Idle 0, Walk 1, Run 2, Rise 3, Fall 4, Jet 5. Reordering
this enum silently reorders the sprite sheet reading from under it.
*/
Player_Motion :: enum u8 {
	Idle,
	Walk,
	Run,
	Rise,
	Fall,
	Jet,
}

// Not in the numbers above, because nothing but this classification
// depends on them. A hair under walking speed reads as standing
// still; a hair over it does not yet read as running.
PLAYER_MOTION_IDLE_SPEED :: 3 // cells per second
PLAYER_MOTION_RUN_MARGIN :: 3 // cells per second past PLAYER_WALK_SPEED

player_motion :: proc(p: Player) -> Player_Motion {
	if p.jetting do return .Jet
	if !p.on_ground && p.vy < 0 do return .Rise
	if !p.on_ground do return .Fall

	speed := abs(p.vx)
	if speed < PLAYER_MOTION_IDLE_SPEED do return .Idle
	if speed > PLAYER_WALK_SPEED + PLAYER_MOTION_RUN_MARGIN do return .Run
	return .Walk
}

// ------------------------------------------------------------
// The player
// ------------------------------------------------------------

/*
Fields are ordered largest-first so the struct holds no interior
padding: six f32 fields (24 bytes) come first, then five byte-sized
flags the compiler can pack together and pad once at the tail, rather
than scattering three bytes of padding between the floats.

x and y are the feet position, in world cells. y is the floor row the
feet rest on, not the top of the body: the body occupies cells
[floor(x - W/2), floor(x + W/2)) across and [floor(y) - H, floor(y))
down. Getting that backward is the difference between the wizard
standing on the ground and hanging with his knees in it.
*/
Player :: struct {
	x, y:   f32, // feet position, in world cells; see above
	vx, vy: f32, // cells per second; y grows downward, like the world
	fuel:   f32, // 0 to PLAYER_FUEL_MAX, tanks in the jetpack
	anim:   f32, // seconds accumulated, for the sprite to pick a frame

	coyote:    u8,  // ticks of ledge grace left
	jet_delay: u8,  // ticks left before a held jump becomes thrust
	facing:    i8,  // +1 right, -1 left
	on_ground: bool,
	jetting:   bool,
}

// Two players per 64-byte cache line; keep it that way.
#assert(size_of(Player) == 32)

// ------------------------------------------------------------
// Collision
// ------------------------------------------------------------

/*
What the wizard collides with: the running Sandbox where it covers
him, and the generator everywhere else. This is the whole join
between the physics and the player (docs/physics.md, "The wizard
meets the sandbox"); every player_* collision helper below takes a
Terrain instead of a World, and nothing about the numbers or the walk
itself changes.

World does NOT gain a sandbox pointer. worldgen.odin's header says why:
generate is stateless and answers any rectangle in any order, which is
the property that lets the world be unbounded, and a mutable pointer
inside World would end that. So the two stay separate fields on a
small struct built fresh by whoever is calling, not a change to World
itself.

sandbox may be nil: the spawn scan builds a Terrain with no sandbox at
all, because a wizard is placed before any physics runs, and a caller
that never asked to follow the play sandbox (a test, the MCP server
opening its own) gets ordinary World collision by passing nil too.
*/
Terrain :: struct {
	world:   World,
	sandbox: ^Sandbox, // may be nil
}

/*
The material at a world cell: the sandbox's, where the sandbox covers
it, or the generator's otherwise.

This is CHEAPER than reading the generator alone, not more expensive:
a sandbox read is one bounds check and one array index, against
world_cell_at's biome lookup and five splitmix64 hashes (worldgen.odin
says why generation costs that). A reader used to the sandbox being
the "slow, mutable" half of the world would assume the opposite, so
this is worth saying plainly: the join makes the wizard faster where
he stands, not slower.
*/
terrain_cell_at :: proc(t: Terrain, wx, wy: i32) -> Cell {
	if t.sandbox != nil {
		sx := wx - t.sandbox.origin_x
		sy := wy - t.sandbox.origin_y
		if sandbox_in_bounds(t.sandbox, sx, sy) {
			return sandbox_cell(t.sandbox, sx, sy)
		}
	}
	return world_cell_at(t.world, wx, wy)
}

// Whether a world cell stops the player. Rock, Gold, Dirt and Sand
// hold him up; Air, Water, Oil, Acid, Lava, Fire, Smoke and Steam do
// not, because only Solid and Powder resist a falling body.
player_solid_at :: proc(t: Terrain, x, y: i32) -> bool {
	c := terrain_cell_at(t, x, y)
	if int(c) >= len(t.world.materials.materials) do return false
	state := t.world.materials.materials[c].state
	return state == .Solid || state == .Powder
}

// The horizontal extent of the body. It does not depend on the feet
// row, so callers that only need this half of the box (the on-ground
// test, the vertical edge test) can skip computing the other half.
@(private = "file")
player_body_x_bounds :: proc(x: f32) -> (x0, x1: i32) {
	return i32(math.floor(x - PLAYER_BODY_W * 0.5)), i32(math.floor(x + PLAYER_BODY_W * 0.5))
}

// The vertical extent of the body: the feet rest on the row at
// floor(y), and the body fills the PLAYER_BODY_H rows above it.
@(private = "file")
player_body_y_bounds :: proc(y: f32) -> (y0, y1: i32) {
	y1 = i32(math.floor(y))
	y0 = y1 - PLAYER_BODY_H
	return
}

/*
Whether the whole body box is free of solid ground: up to
PLAYER_BODY_W * PLAYER_BODY_H, 104, cells.

This is spawn's and de-penetration's proc, not the movement loop's.
world_cell_at costs a biome lookup and five hashes, so a per-substep
call here would multiply that cost by up to 14 substeps a tick. Spawn
and de-penetration each run at most once a tick, which is a cost the
world can afford that the inner loop below cannot.
*/
player_body_clear :: proc(t: Terrain, x, y: f32) -> bool {
	x0, x1 := player_body_x_bounds(x)
	y0, y1 := player_body_y_bounds(y)
	for cy in y0 ..< y1 {
		for cx in x0 ..< x1 {
			if player_solid_at(t, cx, cy) do return false
		}
	}
	return true
}

// Whether the row the feet rest on holds him up, anywhere across the
// body's width. Any one solid cell under him is enough to stand on,
// which matches the edge test below: the same row blocks a downward
// move for the same reason.
@(private = "file")
player_on_ground :: proc(t: Terrain, x, y: f32) -> bool {
	x0, x1 := player_body_x_bounds(x)
	_, y1 := player_body_y_bounds(y)
	for cx in x0 ..< x1 {
		if player_solid_at(t, cx, y1) do return true
	}
	return false
}

/*
The leading edge of a horizontal move at a candidate x: the one column
the body would newly reach, spanning its full height. PLAYER_BODY_H
cells, never the full box.

x and y here are the candidate position, so a caller who wants to test
"can I move to nx" passes nx directly; there is no separate delta.
*/
@(private = "file")
player_edge_clear_x :: proc(t: Terrain, x, y: f32, dir: i32) -> bool {
	x0, x1 := player_body_x_bounds(x)
	y0, y1 := player_body_y_bounds(y)
	edge := dir > 0 ? x1 - 1 : x0
	for cy in y0 ..< y1 {
		if player_solid_at(t, edge, cy) do return false
	}
	return true
}

/*
The leading edge of a vertical move at a candidate y, spanning the
body's full width: PLAYER_BODY_W cells.

Going up that is the top row of the body. Going down it is the row at
floor(y), which the body does NOT occupy: y is the floor his feet rest
on, so the row under his feet is the one that stops him. Testing the
body's own bottom row instead would test a row he already stands in,
which is always clear, and he would sink a whole cell into every floor
before the next row down finally refused him.
*/
@(private = "file")
player_edge_clear_y :: proc(t: Terrain, x, y: f32, dir: i32) -> bool {
	x0, x1 := player_body_x_bounds(x)
	y0, y1 := player_body_y_bounds(y)
	edge := dir > 0 ? y1 : y0
	for cx in x0 ..< x1 {
		if player_solid_at(t, cx, edge) do return false
	}
	return true
}

// The row directly above a body at (x,y), the width of the body. This
// is the ceiling a climb must clear: raising the body past a step is
// no good if his head has nowhere to go once he gets there.
@(private = "file")
player_ceiling_clear :: proc(t: Terrain, x, y: f32) -> bool {
	x0, x1 := player_body_x_bounds(x)
	y0, _ := player_body_y_bounds(y)
	for cx in x0 ..< x1 {
		if player_solid_at(t, cx, y0 - 1) do return false
	}
	return true
}

/*
Drop back to the floor after a climb.

A climb always raises the body the full PLAYER_CLIMB, because testing
every smaller height first would cost up to PLAYER_CLIMB times the
leading-edge test for one step. Most steps are shorter than the
maximum, so afterward he is standing in mid-air above wherever the
real floor is; this walks him back down onto it, one cell at a time,
for at most the cells he was just raised.
*/
@(private = "file")
player_settle :: proc(t: Terrain, x: f32, y: ^f32, max_drop: i32) {
	for _ in 0 ..< max_drop {
		if !player_edge_clear_y(t, x, y^ + 1, 1) do break
		y^ += 1
	}
}

/*
Take a step up rather than stopping at it.

A climb tests the raised body and the ceiling above it, because in a
16 cell channel a climb into rock is the common case, not the corner:
skipping the ceiling test would let him wedge his head into it. Both
tests use the candidate x, so a step he could never fit through
sideways is refused before he is ever moved.
*/
@(private = "file")
player_climb :: proc(t: Terrain, p: ^Player, nx: f32, dir: i32) -> bool {
	raised_y := p.y - PLAYER_CLIMB
	if !player_edge_clear_x(t, nx, raised_y, dir) do return false
	if !player_ceiling_clear(t, nx, raised_y) do return false

	p.x = nx
	p.y = raised_y
	player_settle(t, p.x, &p.y, PLAYER_CLIMB)
	return true
}

// Move current toward target by at most max_delta, and no further.
@(private = "file")
move_toward :: proc(current, target, max_delta: f32) -> f32 {
	if abs(target - current) <= max_delta do return target
	return current + (target > current ? max_delta : -max_delta)
}

// A sentinel jet_delay holds, distinct from every value the ordinary
// countdown passes through. See the comment in player_step on why
// running dry needs one.
PLAYER_JET_LOCKED :: max(u8)

/*
One whole tick at PLAYER_TICK_HZ.

Integration is semi-implicit Euler, velocity first and then position:
every change to vx and vy happens before either is used to move him,
because the two orders give jump heights 2.5 cells apart and only one
of them is 26.7 cells at this tick rate.

jump_pressed is the edge (true for one tick, the tick of the press)
and .Jump in held is the level (true for as long as the key is down).
A press launches him; holding the same key in the air, past
PLAYER_JET_DELAY_TICKS, lights the jetpack instead. Without that
split a held key would always fly, and there would be no jump at all.
*/
player_step :: proc(p: ^Player, t: Terrain, held: Player_Input, jump_pressed: bool) {
	dt : f32 = 1.0 / PLAYER_TICK_HZ

	// De-penetration. The world editor regenerates the world on every
	// paint stroke, so a player can wake up inside rock through no
	// fault of his own. Without this he freezes there for ever: every
	// candidate move starts from a position already inside solid, so
	// the leading edge test never once finds a clear step to take.
	if !player_body_clear(t, p.x, p.y) {
		for up in i32(1) ..= PLAYER_DIG_OUT {
			ny := p.y - f32(up)
			if player_body_clear(t, p.x, ny) {
				p.y = ny
				break
			}
			// Nothing found within range: this tick moves freely, on
			// the chance it carries him toward open air anyway.
		}
	}

	on_ground := player_on_ground(t, p.x, p.y)
	can_jump := on_ground || p.coyote > 0

	// --- horizontal velocity ---
	move_dir : f32 = 0
	if .Left in held do move_dir -= 1
	if .Right in held do move_dir += 1

	if move_dir != 0 {
		target_speed : f32 = .Run in held ? PLAYER_RUN_SPEED : PLAYER_WALK_SPEED
		accel : f32 = on_ground ? PLAYER_GROUND_ACCEL : PLAYER_AIR_ACCEL
		p.vx = move_toward(p.vx, move_dir * target_speed, accel * dt)
		p.facing = move_dir > 0 ? 1 : -1
	} else {
		drag : f32 = on_ground ? PLAYER_GROUND_FRICTION : PLAYER_AIR_DRAG
		p.vx = move_toward(p.vx, 0, drag * dt)
	}

	// --- jump ---
	if jump_pressed && can_jump {
		p.vy = -PLAYER_JUMP_SPEED
		p.coyote = 0
		p.jet_delay = PLAYER_JET_DELAY_TICKS
	}

	// Coyote time starts counting down the moment the ground goes
	// away, and a fresh landing refills it. This runs after the jump
	// check above, so a jump that just spent the grace does not also
	// get a tick knocked off it here.
	if on_ground {
		p.coyote = PLAYER_COYOTE_TICKS
	} else if p.coyote > 0 {
		p.coyote -= 1
	}

	// --- jet delay and thrust ---
	//
	// jet_delay counts down PLAYER_JET_DELAY_TICKS to 0 before a fresh
	// hold lights the jetpack. PLAYER_JET_LOCKED is a second, larger
	// value it can hold: once a burn ends because the tank ran dry,
	// jet_delay is set there instead of back to 0. Held-down fuel fills
	// at PLAYER_FUEL_IN_AIR even while locked, so without this a tiny
	// trickle of it would re-light the instant it cleared zero, a few
	// ticks of thrust would burn it straight back off, and holding the
	// button down would hover him forever on scraps instead of falling.
	// Only letting go, or touching ground, clears the lock.
	thrusting := false
	if .Jump in held && !on_ground {
		if p.jet_delay == PLAYER_JET_LOCKED {
			// Spent for this hold; wait for release.
		} else if p.jet_delay > 0 {
			p.jet_delay -= 1
		} else if p.fuel > 0 {
			thrusting = true
		} else {
			p.jet_delay = PLAYER_JET_LOCKED
		}
	} else {
		p.jet_delay = PLAYER_JET_DELAY_TICKS
	}
	p.jetting = thrusting

	if thrusting {
		p.vy = max(p.vy - PLAYER_JET_ACCEL * dt, -PLAYER_JET_MAX_RISE)
		p.fuel = max(p.fuel - PLAYER_JET_DRAIN * dt, 0)
	} else {
		p.vy = min(p.vy + PLAYER_GRAVITY * dt, PLAYER_MAX_FALL)

		// Fuel does not fill under thrust: a burn has to cost
		// something, or holding the key down is free flight for ever.
		fill : f32 = on_ground ? PLAYER_FUEL_ON_GROUND : PLAYER_FUEL_IN_AIR
		p.fuel = min(p.fuel + fill * dt, PLAYER_FUEL_MAX)
	}

	// --- position: one cell at a time, first contact rather than an
	// arbitrary end position ---
	remaining_x := p.vx * dt
	for remaining_x != 0 {
		d := clamp(remaining_x, -1, 1)
		dir : i32 = d > 0 ? 1 : -1
		nx := p.x + d

		if player_edge_clear_x(t, nx, p.y, dir) {
			p.x = nx
		} else if on_ground && player_climb(t, p, nx, dir) {
			// p.x and p.y were updated inside player_climb.
		} else {
			p.vx = 0 // this axis only: a wall must not cancel a fall
			break
		}
		remaining_x -= d
	}

	remaining_y := p.vy * dt
	for remaining_y != 0 {
		d := clamp(remaining_y, -1, 1)
		dir : i32 = d > 0 ? 1 : -1
		ny := p.y + d

		if player_edge_clear_y(t, p.x, ny, dir) {
			p.y = ny
		} else {
			// Land flush on the row that stopped him rather than
			// wherever in the cell the last substep happened to leave
			// him. Without this he rests at a fraction, and every tick
			// after gravity moves him a little further into the cell
			// until it rounds down: a slow sink into every floor he
			// stands on, and a position that means nothing exact.
			if dir > 0 do p.y = math.floor(ny)
			p.vy = 0
			break
		}
		remaining_y -= d
	}

	p.on_ground = player_on_ground(t, p.x, p.y)
	p.anim += dt

	// Digging happens after the move resolves, so the dig point uses
	// where he actually ended the tick, not where he started it. It
	// runs every tick the button is held, the same level a walk key
	// reads at: docs/physics.md gives digging no separate edge.
	if .Dig in held do player_dig(p^, t)
}

/*
Dig the terrain in front of him: a disc of PLAYER_DIG_RADIUS centred
PLAYER_DIG_REACH cells ahead of his center, in the direction he faces,
at chest height. No cursor is needed and a test can drive it with
nothing but a button and a facing.

Nothing happens with no sandbox under him. sandbox_dig mutates a
running Sandbox; the generator has no dig at all, so a Terrain built
with sandbox = nil (the spawn scan, a caller that never asked to
follow) leaves the world untouched rather than failing.
*/
player_dig :: proc(p: Player, t: Terrain) -> int {
	if t.sandbox == nil do return 0

	wx := i32(p.x) + i32(p.facing) * PLAYER_DIG_REACH
	wy := i32(p.y) - PLAYER_BODY_H / 2
	sx := wx - t.sandbox.origin_x
	sy := wy - t.sandbox.origin_y
	return sandbox_dig(t.sandbox, t.world.materials, sx, sy, PLAYER_DIG_RADIUS, PLAYER_DIG_POWER)
}

// ------------------------------------------------------------
// Spawn
// ------------------------------------------------------------

// The first map row a tiled biome owns. Its top edge is the surface:
// everything above it is open sky, and the spawn search measures
// depth down from here.
@(private = "file")
world_find_surface_row :: proc(world: World) -> (row: i32, found: bool) {
	m := world.biome_map
	for py in 0 ..< m.height {
		for px in 0 ..< m.width {
			id := biome_map_at(m, px, py)
			if id == BIOME_EMPTY do continue
			if world.biomes.biomes[id].tile_base != TILE_NONE do return py, true
		}
	}
	return 0, false
}

// A mouth is a column clear for SPAWN_MOUTH_DEPTH cells below the
// surface: a way down into the caves, not a crack in solid rock. The
// search starts at x 0 and grows outward, so the mouth found is the
// nearest one to the middle of the map, not just the first in scan
// order.
@(private = "file")
world_find_mouth :: proc(t: Terrain, surface_y, min_x, max_x: i32) -> (x: i32, found: bool) {
	is_mouth :: proc(t: Terrain, x, surface_y: i32) -> bool {
		for dy in i32(0) ..< SPAWN_MOUTH_DEPTH {
			if player_solid_at(t, x, surface_y + dy) do return false
		}
		return true
	}

	for dist in i32(0) ..= SPAWN_SEARCH_RANGE {
		right := dist
		if right <= max_x && is_mouth(t, right, surface_y) do return right, true
		left := -dist
		if dist != 0 && left >= min_x && is_mouth(t, left, surface_y) do return left, true
	}
	return 0, false
}

// SPAWN_CLEARANCE cells out from a mouth, in both directions, to the
// nearest column with solid ground at the surface and a clear body
// box above it. The nearest solid column to a mouth is the lip of the
// hole, and an 8 cell body placed there hangs half over the edge and
// falls in on the first tick, which is why the search starts a full
// SPAWN_CLEARANCE out rather than at the mouth itself.
@(private = "file")
world_find_ground_near :: proc(t: Terrain, mouth_x, surface_y: i32) -> (x: i32, found: bool) {
	for dist := i32(SPAWN_CLEARANCE); dist < SPAWN_SEARCH_RANGE; dist += 1 {
		for side in ([2]i32{1, -1}) {
			cx := mouth_x + side * dist
			if !player_solid_at(t, cx, surface_y) do continue
			if !player_body_clear(t, f32(cx), f32(surface_y)) do continue
			return cx, true
		}
	}
	return 0, false
}

/*
If no mouth or ground can be found, stand him in the open sky above
the first tiled region rather than refuse to spawn him at all. A
repainted map can put rock exactly there, so this is tested for
solidity too, not assumed clear: a fallback that itself buries him is
worse than no fallback.
*/
@(private = "file")
world_spawn_fallback :: proc(t: Terrain) -> (x, y: i32, found: bool) {
	surface_row, row_found := world_find_surface_row(t.world)
	if !row_found do return 0, 0, false

	cpp := t.world.biomes.cells_per_pixel
	surface_y := (surface_row - t.world.biomes.origin_pixel_y) * cpp
	fx, fy := i32(0), surface_y - SPAWN_CLEARANCE

	if !player_body_clear(t, f32(fx), f32(fy)) do return 0, 0, false
	return fx, fy, true
}

/*
Where he starts: beside a hole, not in it.

	1. Find the surface: the top edge of the first map row a tiled
	   biome owns.
	2. Scan for a mouth: a column clear for SPAWN_MOUTH_DEPTH cells
	   below the surface.
	3. Step SPAWN_CLEARANCE cells out from the mouth to solid ground
	   with a clear body box above it.

Any step that finds nothing falls back to world_spawn_fallback.

This builds its own Terrain with no sandbox, because a wizard is
placed before any physics runs (docs/physics.md, "The wizard meets the
sandbox"): there is nothing yet for the scan to read but the
generator. player_spawn keeps taking a plain World, so nothing outside
this file has to know a Terrain exists just to place him.
*/
world_find_spawn :: proc(world: World) -> (x, y: i32, found: bool) {
	t := Terrain{world = world}

	surface_row, row_found := world_find_surface_row(world)
	if !row_found do return world_spawn_fallback(t)

	cpp := world.biomes.cells_per_pixel
	surface_y := (surface_row - world.biomes.origin_pixel_y) * cpp

	m := world.biome_map
	min_x := (0 - world.biomes.origin_pixel_x) * cpp
	max_x := (m.width - world.biomes.origin_pixel_x) * cpp - 1

	mouth_x, mouth_found := world_find_mouth(t, surface_y, min_x, max_x)
	if !mouth_found do return world_spawn_fallback(t)

	ground_x, ground_found := world_find_ground_near(t, mouth_x, surface_y)
	if !ground_found do return world_spawn_fallback(t)

	return ground_x, surface_y, true
}

/*
A fresh wizard: found and standing, or at the world's fallback spot if
even that fails, facing right with a full tank.

on_ground is asked of the world rather than left false. A spawn that
reports itself airborne makes the first frame draw a falling wizard on
solid ground, and every caller that only wants to place him and look at
him has to run a physics tick or patch the flag by hand. The world
already knows the answer, so this asks it once.
*/
player_spawn :: proc(world: World) -> Player {
	x, y, found := world_find_spawn(world)
	if !found do x, y = 0, 0

	return Player{
		x         = f32(x),
		y         = f32(y),
		facing    = 1,
		fuel      = PLAYER_FUEL_MAX,
		on_ground = player_on_ground(Terrain{world = world}, f32(x), f32(y)),
	}
}

// ------------------------------------------------------------
// Tests (run with: odin test src  from repo root)
// ------------------------------------------------------------

// Two biomes, both uniform fill, so no tile set has to load: Rock
// holds him up and Air does not. cells_per_pixel is 1, so one map
// pixel is one world cell and a test can paint an exact wall, step or
// ceiling instead of hoping a procedural cave happens to have one.
// Anything left unpainted reads as the off-map biome, which is Rock,
// so a test that never paints a cell gets solid ground under it and a
// test that walks off the edge of its painted area meets a wall
// rather than an infinite drop.
@(private = "file")
PLAYER_TEST_ROCK :: Biome_Id(0)
@(private = "file")
PLAYER_TEST_AIR :: Biome_Id(1)

@(private = "file")
make_flat_world :: proc(t: ^testing.T, width, height: i32) -> (world: World, ok: bool) {
	materials, mat_ok := load_materials("data/materials.txt")
	if !testing.expect(t, mat_ok, "materials must load") do return {}, false

	rock, rock_found := find_material_index(materials, "Rock")
	air, air_found := find_material_index(materials, "Air")
	if !testing.expect(t, rock_found && air_found, "Rock and Air must exist") {
		destroy_material_table(materials)
		return {}, false
	}

	biomes := make([]Biome, 2)
	biomes[PLAYER_TEST_ROCK] = Biome{fill_0 = u16(rock), tile_base = TILE_NONE, variants = 1, generator = .Uniform}
	biomes[PLAYER_TEST_AIR] = Biome{fill_0 = u16(air), tile_base = TILE_NONE, variants = 1, generator = .Uniform}

	table := Biome_Table {
		biomes          = biomes,
		names           = make([]string, 2),
		tile_prefixes   = make([]string, 2),
		cells_per_pixel = 1,
		off_map_biome   = PLAYER_TEST_ROCK,
	}

	m := make_biome_map(width, height)
	return World{materials = materials, biomes = table, biome_map = m, tiles = Tile_Set{}, seed = 0}, true
}

@(private = "file")
destroy_flat_world :: proc(world: World) {
	destroy_biome_map(world.biome_map)
	delete(world.biomes.names)
	delete(world.biomes.tile_prefixes)
	delete(world.biomes.biomes)
	destroy_material_table(world.materials)
}

// Open sky in every row above floor_row, across the whole map width.
// Rows at and below floor_row are left unpainted, which is solid Rock.
@(private = "file")
carve_open_floor :: proc(world: World, floor_row: i32) {
	for y in i32(0) ..< floor_row {
		for x in i32(0) ..< world.biome_map.width do biome_map_set(world.biome_map, x, y, PLAYER_TEST_AIR)
	}
}

// The whole map, open air. Used where a test needs no ground nearby
// at all.
@(private = "file")
carve_all_air :: proc(world: World) {
	for y in i32(0) ..< world.biome_map.height {
		for x in i32(0) ..< world.biome_map.width do biome_map_set(world.biome_map, x, y, PLAYER_TEST_AIR)
	}
}

@(test)
test_a_dropped_wizard_lands_on_the_floor :: proc(t: ^testing.T) {
	world, ok := make_flat_world(t, 64, 64)
	if !ok do return
	defer destroy_flat_world(world)
	carve_open_floor(world, 40)
	terrain := Terrain{world = world}

	p := Player{x = 32, y = 10, facing = 1}
	for _ in 0 ..< 300 do player_step(&p, terrain, {}, false)

	testing.expectf(t, i32(math.floor(p.y)) == 40, "the feet must rest on the floor row, got y=%f", p.y)
	testing.expectf(t, p.vy == 0, "he must stop falling once he lands, got vy=%f", p.vy)
	testing.expect(t, p.on_ground, "on_ground must be true once he has landed")
	testing.expect(t, player_body_clear(terrain, p.x, p.y), "the body must be clear of the floor he stands on")
}

@(test)
test_he_does_not_pass_through_a_wall :: proc(t: ^testing.T) {
	world, ok := make_flat_world(t, 200, 60)
	if !ok do return
	defer destroy_flat_world(world)
	carve_open_floor(world, 20)
	// A wall from the ground up into the open sky, columns 60 to 69.
	for y in i32(0) ..< 20 {
		for x in i32(60) ..< 70 do biome_map_set(world.biome_map, x, y, PLAYER_TEST_ROCK)
	}
	terrain := Terrain{world = world}

	p := Player{x = 10, y = 20, facing = 1}
	for _ in 0 ..< 400 {
		player_step(&p, terrain, {.Right, .Run}, false)
		testing.expect(t, player_body_clear(terrain, p.x, p.y), "the body must never overlap solid at the end of a tick")
	}

	testing.expect(t, p.vx == 0, "the wall must stop his horizontal speed")
	x1 := i32(math.floor(p.x + PLAYER_BODY_W * 0.5))
	testing.expectf(t, x1 == 60, "he must come to rest flush against the wall, got right edge %d", x1)
}

@(test)
test_hitting_a_wall_does_not_cancel_a_fall :: proc(t: ^testing.T) {
	world, ok := make_flat_world(t, 100, 2000)
	if !ok do return
	defer destroy_flat_world(world)
	carve_all_air(world)
	// A wall with no floor at its foot: it spans the whole map, so
	// sliding down its face never lands him anywhere, and the test
	// stays about the wall rather than about the ground below it.
	for y in i32(0) ..< 2000 {
		for x in i32(15) ..< 25 do biome_map_set(world.biome_map, x, y, PLAYER_TEST_ROCK)
	}
	terrain := Terrain{world = world}

	p := Player{x = 5, y = 1000, facing = 1}
	for _ in 0 ..< 60 do player_step(&p, terrain, {.Right, .Run}, false)

	testing.expect(t, p.vx == 0, "the wall must have stopped him by now")
	testing.expect(t, !p.on_ground, "there is no floor here: he must still be airborne")
	testing.expectf(t, p.vy > 100, "gravity must still be acting on him, got vy=%f", p.vy)
}

@(test)
test_walking_and_running_hold_their_speeds :: proc(t: ^testing.T) {
	world, ok := make_flat_world(t, 2000, 40)
	if !ok do return
	defer destroy_flat_world(world)
	carve_open_floor(world, 20)
	terrain := Terrain{world = world}

	walk := Player{x = 100, y = 20, facing = 1}
	max_walk := f32(0)
	for _ in 0 ..< 180 {
		player_step(&walk, terrain, {.Right}, false)
		max_walk = max(max_walk, walk.vx)
	}
	testing.expectf(t, max_walk <= PLAYER_WALK_SPEED + 0.01, "walking must never exceed PLAYER_WALK_SPEED, got %f", max_walk)
	testing.expectf(t, abs(walk.vx - PLAYER_WALK_SPEED) < 0.5, "walking must hold PLAYER_WALK_SPEED, got %f", walk.vx)

	run := Player{x = 100, y = 20, facing = 1}
	max_run := f32(0)
	for _ in 0 ..< 180 {
		player_step(&run, terrain, {.Right, .Run}, false)
		max_run = max(max_run, run.vx)
	}
	testing.expectf(t, max_run <= PLAYER_RUN_SPEED + 0.01, "running must never exceed PLAYER_RUN_SPEED, got %f", max_run)
	testing.expectf(t, abs(run.vx - PLAYER_RUN_SPEED) < 0.5, "running must hold PLAYER_RUN_SPEED, got %f", run.vx)
}

@(test)
test_a_jump_from_the_ground_rises_and_returns_to_the_ground :: proc(t: ^testing.T) {
	world, ok := make_flat_world(t, 40, 200)
	if !ok do return
	defer destroy_flat_world(world)
	carve_open_floor(world, 150)
	terrain := Terrain{world = world}

	p := Player{x = 20, y = 150, facing = 1}
	start_y := p.y
	min_y := p.y

	player_step(&p, terrain, {.Jump}, true)
	min_y = min(min_y, p.y)
	for _ in 0 ..< 300 {
		player_step(&p, terrain, {}, false) // released: no thrust, a pure arc
		min_y = min(min_y, p.y)
		if p.on_ground && p.vy == 0 do break
	}

	apex := start_y - min_y
	testing.expectf(t, abs(apex - 26.7) <= 2.0, "the apex must land within a cell or two of 26.7 cells, got %f", apex)
	testing.expect(t, p.on_ground, "he must come back down to the ground")
}

@(test)
test_a_jump_press_with_no_ground_and_no_coyote_does_not_change_vy :: proc(t: ^testing.T) {
	world, ok := make_flat_world(t, 20, 20)
	if !ok do return
	defer destroy_flat_world(world)
	carve_all_air(world)
	terrain := Terrain{world = world}

	p := Player{x = 10, y = 10, vy = 50, facing = 1} // already falling, coyote already spent
	before := p.vy
	player_step(&p, terrain, {}, true)

	testing.expectf(t, p.vy != -PLAYER_JUMP_SPEED, "a jump with no ground and no coyote must not launch him, got vy=%f", p.vy)
	testing.expectf(t, p.vy > before, "gravity must still apply, got vy=%f from %f", p.vy, before)
}

@(test)
test_coyote_time_lets_him_jump_soon_after_a_ledge_but_not_later :: proc(t: ^testing.T) {
	world, ok := make_flat_world(t, 100, 250)
	if !ok do return
	defer destroy_flat_world(world)

	// A platform under x < 40; open air, all the way down, at and past it.
	for y in i32(0) ..< 20 {
		for x in i32(0) ..< 100 do biome_map_set(world.biome_map, x, y, PLAYER_TEST_AIR)
	}
	for y in i32(20) ..< 250 {
		for x in i32(40) ..< 100 do biome_map_set(world.biome_map, x, y, PLAYER_TEST_AIR)
	}
	terrain := Terrain{world = world}

	p := Player{x = 30, y = 20, facing = 1}
	for _ in 0 ..< 500 {
		player_step(&p, terrain, {.Right}, false)
		if !p.on_ground do break
	}
	// p now holds the state right after the first tick off the platform.

	first_failing_tick := -1
	for tick in 0 ..< int(PLAYER_COYOTE_TICKS) + 4 {
		trial := p
		for _ in 0 ..< tick do player_step(&trial, terrain, {}, false)
		player_step(&trial, terrain, {}, true)
		if trial.vy >= 0 && first_failing_tick == -1 {
			first_failing_tick = tick
		}
	}

	testing.expectf(
		t,
		first_failing_tick == int(PLAYER_COYOTE_TICKS),
		"the grace period must last exactly PLAYER_COYOTE_TICKS ticks after the ledge, but it ended at tick %d",
		first_failing_tick,
	)
}

@(test)
test_he_climbs_a_step_of_exactly_the_climb_height_and_is_stopped_by_a_taller_one :: proc(t: ^testing.T) {
	make_step_world :: proc(t: ^testing.T, step_height: i32) -> (world: World, ok: bool) {
		world, ok = make_flat_world(t, 120, 250)
		if !ok do return
		for y in i32(0) ..< 20 {
			for x in i32(0) ..< 50 do biome_map_set(world.biome_map, x, y, PLAYER_TEST_AIR)
		}
		for y in i32(0) ..< 20 - step_height {
			for x in i32(50) ..< 120 do biome_map_set(world.biome_map, x, y, PLAYER_TEST_AIR)
		}
		return world, true
	}

	{
		world, ok := make_step_world(t, PLAYER_CLIMB)
		if !ok do return
		defer destroy_flat_world(world)
		terrain := Terrain{world = world}

		p := Player{x = 30, y = 20, facing = 1}
		for _ in 0 ..< 300 do player_step(&p, terrain, {.Right}, false)

		testing.expectf(t, p.x > 54, "a step of exactly PLAYER_CLIMB must be climbed, got x=%f", p.x)
		testing.expect(t, p.on_ground, "he must be standing once he is over the step")
		testing.expectf(
			t, i32(math.floor(p.y)) == 20 - PLAYER_CLIMB,
			"his feet must rest on the raised platform, got y=%f", p.y,
		)
	}
	{
		world, ok := make_step_world(t, PLAYER_CLIMB + 1)
		if !ok do return
		defer destroy_flat_world(world)
		terrain := Terrain{world = world}

		p := Player{x = 30, y = 20, facing = 1}
		for _ in 0 ..< 300 do player_step(&p, terrain, {.Right}, false)

		x1 := i32(math.floor(p.x + PLAYER_BODY_W * 0.5))
		testing.expectf(t, x1 == 50, "a step one cell taller than PLAYER_CLIMB must stop him at it, got right edge %d", x1)
		testing.expect(t, p.vx == 0, "he must be stopped by the taller step")
		testing.expect(t, p.on_ground, "he must still be standing on the lower floor")
	}
}

@(test)
test_a_climb_under_a_low_ceiling_is_refused :: proc(t: ^testing.T) {
	world, ok := make_flat_world(t, 120, 250)
	if !ok do return
	defer destroy_flat_world(world)

	for y in i32(0) ..< 20 {
		for x in i32(0) ..< 50 do biome_map_set(world.biome_map, x, y, PLAYER_TEST_AIR)
	}
	// A step exactly PLAYER_CLIMB tall, with exactly PLAYER_BODY_H of
	// headroom above it and rock past that: the raised body itself
	// fits, so only the ceiling test can catch this.
	for y in i32(4) ..< 20 - PLAYER_CLIMB {
		for x in i32(50) ..< 120 do biome_map_set(world.biome_map, x, y, PLAYER_TEST_AIR)
	}
	terrain := Terrain{world = world}

	p := Player{x = 30, y = 20, facing = 1}
	for _ in 0 ..< 300 do player_step(&p, terrain, {.Right}, false)

	testing.expectf(t, i32(math.floor(p.y)) == 20, "a refused climb must leave him on the lower floor, got y=%f", p.y)
	testing.expect(t, p.vx == 0, "the wall must stop him rather than wedge him in rock")
	testing.expect(t, player_body_clear(terrain, p.x, p.y), "he must not end up inside rock")
}

@(test)
test_the_jetpack_lifts_him_drains_the_tank_and_he_falls_when_empty :: proc(t: ^testing.T) {
	// Tall enough that falling at terminal speed for the whole test
	// never reaches the off-map floor below the painted air: hitting
	// that would land him, refuel him, and quietly pass a broken test.
	world, ok := make_flat_world(t, 40, 20000)
	if !ok do return
	defer destroy_flat_world(world)
	carve_all_air(world)
	terrain := Terrain{world = world}

	p := Player{x = 20, y = 5000, fuel = PLAYER_FUEL_MAX, facing = 1}
	start_y := p.y
	min_y := p.y
	thrust_ticks := 0
	emptied := false

	for _ in 0 ..< 400 {
		player_step(&p, terrain, {.Jump}, false)
		if p.jetting do thrust_ticks += 1
		if p.fuel <= 0 do emptied = true
		min_y = min(min_y, p.y)
	}

	testing.expect(t, emptied, "holding the jetpack down must eventually run the tank dry")
	testing.expectf(t, min_y < start_y - 50, "the jetpack must lift him well off the ground, got min y=%f from %f", min_y, start_y)
	testing.expectf(
		t, abs(f32(thrust_ticks) / PLAYER_TICK_HZ - 2.0) < 0.1,
		"the burn must last about 2.0 seconds, got %d ticks", thrust_ticks,
	)

	falling := false
	for _ in 0 ..< 60 {
		player_step(&p, terrain, {.Jump}, false)
		if p.vy > 50 do falling = true
	}
	testing.expect(t, falling, "he must fall once the tank runs dry, even while still holding the button")
}

@(test)
test_the_tank_fills_on_the_ground_more_slowly_in_the_air_and_not_while_thrusting :: proc(t: ^testing.T) {
	ground_world, ok1 := make_flat_world(t, 40, 40)
	if !ok1 do return
	defer destroy_flat_world(ground_world)
	carve_open_floor(ground_world, 20)
	ground_terrain := Terrain{world = ground_world}

	standing := Player{x = 20, y = 20, fuel = 0, facing = 1}
	player_step(&standing, ground_terrain, {}, false)
	testing.expect(t, standing.on_ground, "he must be standing for this part of the test")
	testing.expectf(
		t, abs(standing.fuel - PLAYER_FUEL_ON_GROUND / PLAYER_TICK_HZ) < 0.001,
		"standing must fill fuel at PLAYER_FUEL_ON_GROUND, got %f", standing.fuel,
	)

	air_world, ok2 := make_flat_world(t, 40, 2000)
	if !ok2 do return
	defer destroy_flat_world(air_world)
	carve_all_air(air_world)
	air_terrain := Terrain{world = air_world}

	falling := Player{x = 20, y = 1000, fuel = 0, facing = 1}
	player_step(&falling, air_terrain, {}, false)
	testing.expect(t, !falling.on_ground, "he must be airborne for this part of the test")
	testing.expectf(
		t, abs(falling.fuel - PLAYER_FUEL_IN_AIR / PLAYER_TICK_HZ) < 0.001,
		"falling must fill fuel at PLAYER_FUEL_IN_AIR, got %f", falling.fuel,
	)
	testing.expect(t, falling.fuel < standing.fuel, "the air fill rate must be slower than the ground rate")

	thrusting := Player{x = 20, y = 1000, fuel = PLAYER_FUEL_MAX, jet_delay = 0, facing = 1}
	player_step(&thrusting, air_terrain, {.Jump}, false)
	testing.expect(t, thrusting.jetting, "he must be thrusting for this part of the test")
	testing.expectf(t, thrusting.fuel < PLAYER_FUEL_MAX, "thrusting must drain fuel, not fill it, got %f", thrusting.fuel)
}

@(test)
test_a_player_buried_in_rock_reaches_open_air_within_dig_out_and_is_not_frozen :: proc(t: ^testing.T) {
	world, ok := make_flat_world(t, 60, 400)
	if !ok do return
	defer destroy_flat_world(world)

	// Open air from row 200 up; solid rock below it. He starts buried
	// exactly PLAYER_DIG_OUT cells under the surface of the air.
	for y in i32(0) ..< 200 {
		for x in i32(0) ..< 60 do biome_map_set(world.biome_map, x, y, PLAYER_TEST_AIR)
	}
	buried_y := i32(200) + PLAYER_DIG_OUT
	terrain := Terrain{world = world}

	p := Player{x = 30, y = f32(buried_y), facing = 1}
	testing.expect(t, !player_body_clear(terrain, p.x, p.y), "the setup must actually start him buried")

	player_step(&p, terrain, {}, false)

	testing.expect(t, player_body_clear(terrain, p.x, p.y), "he must reach open air within PLAYER_DIG_OUT")
	testing.expectf(t, p.y < f32(buried_y), "de-penetration must move him toward the surface, got y=%f", p.y)

	before_x := p.x
	for _ in 0 ..< 30 do player_step(&p, terrain, {.Right}, false)
	testing.expectf(t, p.x > before_x, "he must not be frozen: he must be able to walk once he is out, got x=%f from %f", p.x, before_x)
}

@(test)
test_the_same_input_list_gives_the_same_position_twice :: proc(t: ^testing.T) {
	world, ok := make_flat_world(t, 200, 300)
	if !ok do return
	defer destroy_flat_world(world)
	carve_open_floor(world, 200)
	terrain := Terrain{world = world}

	Recorded_Input :: struct {
		held: Player_Input,
		jump: bool,
	}
	inputs := []Recorded_Input {
		{{.Right}, false}, {{.Right}, false}, {{.Right, .Run}, false},
		{{.Right, .Run, .Jump}, true}, {{.Jump}, false}, {{.Jump}, false},
		{{.Jump}, false}, {{.Jump}, false}, {{.Jump}, false}, {{.Jump}, false},
		{{.Jump}, false}, {{.Jump}, false}, {{}, false}, {{.Left}, false},
		{{.Left}, false}, {{}, false}, {{}, false}, {{}, false},
	}

	run :: proc(t: Terrain, inputs: []Recorded_Input) -> (f32, f32) {
		p := Player{x = 100, y = 200, facing = 1}
		for step in inputs do player_step(&p, t, step.held, step.jump)
		return p.x, p.y
	}

	x1, y1 := run(terrain, inputs)
	x2, y2 := run(terrain, inputs)
	testing.expect(t, x1 == x2 && y1 == y2, "the same input list must give the same position twice")
}

/*
terrain_cell_at is the whole join, so it gets its own test rather than
riding along inside a player test: the sandbox rect sits astride zero,
so a coordinate on the wrong side of floor_div would read the wrong
half silently, and this exercises both the near and the far corner of
it plus a cell well outside it at a negative coordinate.
*/
@(test)
test_terrain_cell_at_reads_the_sandbox_inside_its_rect_and_the_world_outside_it :: proc(t: ^testing.T) {
	world, ok := make_flat_world(t, 4000, 40)
	if !ok do return
	defer destroy_flat_world(world)
	carve_all_air(world)

	sand, sand_found := find_material_index(world.materials, "Sand")
	if !testing.expect(t, sand_found, "Sand must exist in the material table") do return

	sb, sb_ok := sandbox_make(8, 8, 1)
	if !testing.expect(t, sb_ok, "the sandbox must open") do return
	defer sandbox_destroy(&sb)
	sb.origin_x = -1004
	sb.origin_y = -2
	for i in 0 ..< len(sb.cells) do sb.cells[i] = Cell(sand)

	terrain := Terrain{world = world, sandbox = &sb}

	testing.expect(
		t, terrain_cell_at(terrain, sb.origin_x, sb.origin_y) == Cell(sand),
		"the near corner of the rect must read the sandbox",
	)
	testing.expect(
		t, terrain_cell_at(terrain, sb.origin_x + 7, sb.origin_y + 7) == Cell(sand),
		"the far corner of the rect must read the sandbox too",
	)

	outside_x, outside_y := sb.origin_x - 1, sb.origin_y
	testing.expect(
		t, terrain_cell_at(terrain, outside_x, outside_y) == world_cell_at(world, outside_x, outside_y),
		"one cell left of the rect must read the generator, not the sandbox",
	)
	testing.expectf(
		t, terrain_cell_at(terrain, -9000, 3) == world_cell_at(world, -9000, 3),
		"far outside the rect, at a negative world coordinate, must still match the generator",
	)
}

/*
The test that proves the join docs/player.md used to say never
happened. The world alone is open air all the way down: with no
sandbox a wizard here falls forever. Add a sandbox holding sand where
the world holds nothing but air, and the same position must read solid
ground, because Terrain reads the sandbox first.
*/
@(test)
test_he_stands_on_sand_that_exists_only_in_the_sandbox :: proc(t: ^testing.T) {
	world, ok := make_flat_world(t, 200, 4000)
	if !ok do return
	defer destroy_flat_world(world)
	carve_all_air(world)

	sand, sand_found := find_material_index(world.materials, "Sand")
	if !testing.expect(t, sand_found, "Sand must exist in the material table") do return

	sb, sb_ok := sandbox_make(64, 64, 1)
	if !testing.expect(t, sb_ok, "the sandbox must open") do return
	defer sandbox_destroy(&sb)
	sb.origin_x = 50
	sb.origin_y = 100
	// A floor of sand across the sandbox from row 40 down; air above it.
	for y in i32(0) ..< sb.height {
		for x in i32(0) ..< sb.width {
			sb.cells[sandbox_index(&sb, x, y)] = y >= 40 ? Cell(sand) : MATERIAL_AIR
		}
	}

	terrain_no_sandbox := Terrain{world = world}
	terrain_with_sandbox := Terrain{world = world, sandbox = &sb}

	px := f32(sb.origin_x + 32)
	py := f32(sb.origin_y + 40) // the world y of the sand row

	without := Player{x = px, y = py - 5, facing = 1}
	for _ in 0 ..< 300 do player_step(&without, terrain_no_sandbox, {}, false)
	testing.expect(t, !without.on_ground, "with no sandbox there is nothing under him: he must still be falling")

	with := Player{x = px, y = py - 5, facing = 1}
	for _ in 0 ..< 300 do player_step(&with, terrain_with_sandbox, {}, false)
	testing.expect(t, with.on_ground, "the sandbox's sand must hold him up, though the world under it is empty air")
	testing.expectf(t, i32(math.floor(with.y)) == sb.origin_y + 40, "he must land on the sand row, got y=%f", with.y)
}

/*
Sandbox physics reaching the player: dig the floor out from under him
and he must fall through it, not hang on the rock the generator would
still hold there underneath.
*/
@(test)
test_digging_the_floor_out_from_under_him_makes_him_fall :: proc(t: ^testing.T) {
	world, ok := make_flat_world(t, 200, 200)
	if !ok do return
	defer destroy_flat_world(world)
	carve_open_floor(world, 100) // air above row 100; rock at and below it

	sb, sb_ok := sandbox_make(64, 64, 1)
	if !testing.expect(t, sb_ok, "the sandbox must open") do return
	defer sandbox_destroy(&sb)
	sandbox_fill_from_world(&sb, world, 40, 70)

	terrain := Terrain{world = world, sandbox = &sb}

	p := Player{x = 72, y = 100, facing = 1}
	for _ in 0 ..< 10 do player_step(&p, terrain, {}, false)
	testing.expect(t, p.on_ground, "he must be standing on the sandbox's copy of the rock floor first")

	// Dig the floor out from under him: sandbox-local (32,30) is world
	// (72,100), exactly where he stands.
	sandbox_dig(&sb, world.materials, 32, 30, 6, 255)

	// A handful of ticks, not a long settle: the dig is a disc, not a
	// bottomless shaft, so given long enough he falls clean through it
	// and lands again on the rock below. This only has to catch him
	// leaving the ground he started on.
	for _ in 0 ..< 5 do player_step(&p, terrain, {}, false)
	testing.expect(t, !p.on_ground, "the floor is gone from the sandbox: he must fall through it")
	testing.expectf(t, p.vy > 0, "gravity must be pulling him down through the hole, got vy=%f", p.vy)
}

/*
Player_Button.Dig, driven by nothing but a button and a facing: no
cursor is needed, so a test can hold the button and check the cell in
front of his chest.
*/
@(test)
test_holding_dig_removes_sandbox_material_in_front_of_him :: proc(t: ^testing.T) {
	world, ok := make_flat_world(t, 200, 60)
	if !ok do return
	defer destroy_flat_world(world)
	carve_open_floor(world, 30)

	sand, sand_found := find_material_index(world.materials, "Sand")
	if !testing.expect(t, sand_found, "Sand must exist in the material table") do return

	sb, sb_ok := sandbox_make(8, 8, 1)
	if !testing.expect(t, sb_ok, "the sandbox must open") do return
	defer sandbox_destroy(&sb)
	sb.origin_x = 54
	sb.origin_y = 20
	for i in 0 ..< len(sb.cells) do sb.cells[i] = Cell(sand)

	terrain := Terrain{world = world, sandbox = &sb}

	p := Player{x = 50, y = 30, facing = 1}
	for _ in 0 ..< 5 do player_step(&p, terrain, {}, false) // settle onto the world's own floor
	testing.expect(t, p.on_ground, "he must be standing before the dig starts")

	dig_x := i32(p.x) + i32(p.facing) * PLAYER_DIG_REACH - sb.origin_x
	dig_y := i32(p.y) - PLAYER_BODY_H / 2 - sb.origin_y
	testing.expect(t, sandbox_cell(&sb, dig_x, dig_y) == Cell(sand), "the dig point must start as sand")

	player_step(&p, terrain, {.Dig}, false)

	testing.expect(t, sandbox_cell(&sb, dig_x, dig_y) != Cell(sand), "holding Dig must clear the sand at the dig point")
}

@(test)
test_player_motion_reads_state_into_the_sprite_sheet_rows :: proc(t: ^testing.T) {
	testing.expect(t, player_motion(Player{on_ground = true}) == .Idle)
	testing.expect(t, player_motion(Player{on_ground = true, vx = PLAYER_WALK_SPEED}) == .Walk)
	testing.expect(t, player_motion(Player{on_ground = true, vx = -PLAYER_WALK_SPEED}) == .Walk, "facing left must still read")
	testing.expect(t, player_motion(Player{on_ground = true, vx = PLAYER_RUN_SPEED}) == .Run)
	testing.expect(t, player_motion(Player{on_ground = false, vy = -50}) == .Rise)
	testing.expect(t, player_motion(Player{on_ground = false, vy = 50}) == .Fall)
	testing.expect(t, player_motion(Player{on_ground = false, vy = -50, jetting = true}) == .Jet, "thrust must win over rise")
}

@(test)
test_world_find_spawn_on_the_shipped_map :: proc(t: ^testing.T) {
	s: Sim
	if !testing.expect(t, sim_load(&s) == .None, "the world must load") do return
	defer sim_unload(&s)

	terrain := Terrain{world = s.world}

	x, y, found := world_find_spawn(s.world)
	if !testing.expect(t, found, "the shipped map must offer a spawn point") do return

	testing.expect(t, player_solid_at(terrain, x, y), "the feet must be on solid ground")
	testing.expect(t, player_body_clear(terrain, f32(x), f32(y)), "the whole body box must be clear")

	surface_row, row_found := world_find_surface_row(s.world)
	if !testing.expect(t, row_found) do return
	cpp := s.world.biomes.cells_per_pixel
	surface_y := (surface_row - s.world.biomes.origin_pixel_y) * cpp
	testing.expectf(t, y == surface_y, "he must spawn on the surface row, got y=%d want %d", y, surface_y)

	min_x := (0 - s.world.biomes.origin_pixel_x) * cpp
	max_x := (s.world.biome_map.width - s.world.biomes.origin_pixel_x) * cpp - 1
	mouth_x, mouth_found := world_find_mouth(terrain, surface_y, min_x, max_x)
	if !testing.expect(t, mouth_found, "the shipped map must have a mouth into the caves") do return
	testing.expectf(
		t, abs(x - mouth_x) < 200,
		"the spawn must sit a sensible distance from the mouth it was found beside, got x=%d mouth=%d", x, mouth_x,
	)
}

/*
Beside the hole, not in it.

The two tests above say the spawn cell is solid and the body box is
clear, which a cell on the very lip of a mouth also satisfies. Neither
of them says he is still there a second later. This runs him with no
buttons held, which is what a player sees before touching anything: if
the spawn hangs him over the edge, gravity finds out.
*/
@(test)
test_a_fresh_wizard_stands_where_he_spawned :: proc(t: ^testing.T) {
	s: Sim
	if !testing.expect(t, sim_load(&s) == .None, "the world must load") do return
	defer sim_unload(&s)

	terrain := Terrain{world = s.world}
	p := player_spawn(s.world)
	testing.expect(t, p.on_ground, "a wizard spawned on solid ground must know he is standing")

	start_x, start_y := p.x, p.y
	for _ in 0 ..< PLAYER_TICK_HZ {
		player_step(&p, terrain, {}, false)
	}

	testing.expectf(
		t, p.y == start_y,
		"he must not sink or fall in the first second, from y=%v to y=%v", start_y, p.y,
	)
	testing.expectf(
		t, p.x == start_x,
		"nothing pushes a wizard who holds no key, and he moved from x=%v to x=%v", start_x, p.x,
	)
	testing.expect(t, p.on_ground, "he must still be standing")
	testing.expect(t, player_body_clear(terrain, p.x, p.y), "and still clear of the ground")
}

/*
The clear channel through one WANG_SEAM band of a tile: the cells open
through every row (north or south) or every column (east or west) of
the band, not just one of them. A body that only needs to clear one
row of the band could still be pinched by rock in another, so the
intersection across the whole band is what actually gets him through.
*/
@(private = "file")
tile_band_channel :: proc(set: Tile_Set, id: Tile_Id, materials: Material_Table, side: Wang_Band) -> int {
	is_clear :: proc(set: Tile_Set, id: Tile_Id, materials: Material_Table, x, y: i32) -> bool {
		c := tile_at(set, id, x, y)
		if int(c) >= len(materials.materials) do return false
		state := materials.materials[c].state
		return state != .Solid && state != .Powder
	}

	// The longest unbroken run, not the total. A body passes through one
	// opening or none: a band with two gaps of six cells holds twelve
	// clear cells and stops a body of seven.
	longest, run := 0, 0
	count :: proc(open: bool, longest, run: ^int) {
		run^ = open ? run^ + 1 : 0
		if run^ > longest^ do longest^ = run^
	}

	switch side {
	case .North, .South:
		// The opening runs along x, so this band limits how WIDE he can be.
		y0 : i32 = side == .North ? 0 : TILE_SIZE - WANG_SEAM
		for x in i32(WANG_SEAM) ..< TILE_SIZE - WANG_SEAM {
			open := true
			for y in y0 ..< y0 + WANG_SEAM {
				if !is_clear(set, id, materials, x, y) {
					open = false
					break
				}
			}
			count(open, &longest, &run)
		}
	case .East, .West:
		// The opening runs along y, so this band limits how TALL he can be.
		x0 : i32 = side == .West ? 0 : TILE_SIZE - WANG_SEAM
		for y in i32(WANG_SEAM) ..< TILE_SIZE - WANG_SEAM {
			open := true
			for x in x0 ..< x0 + WANG_SEAM {
				if !is_clear(set, id, materials, x, y) {
					open = false
					break
				}
			}
			count(open, &longest, &run)
		}
	case .Inside, .Corner:
	}
	return longest
}

/*
The regression guard for the whole feature.

For every tile of every biome that owns a set, for every side that
carries edge colour 1, this measures the clear channel through that
side's WANG_SEAM band and holds it to what the body actually needs. A
north or south band's opening runs along x and so limits how wide he
can be; an east or west band's opening runs along y and limits how
tall. Reseed a tile set with a narrower mouth and this test says so
before a player finds out.

It holds the sets to two different floors. The per-tile one is the
body: a channel under it seals him in. The one at the end is the
world: a channel over the body and under several of it is a world he
fits through and does not walk through, which is what the sets used to
draw and what PLAYER_WORLD_CHANNEL now refuses.
*/
@(test)
test_the_player_fits_the_world :: proc(t: ^testing.T) {
	s: Sim
	if !testing.expect(t, sim_load(&s) == .None, "the world must load") do return
	defer sim_unload(&s)

	// The narrowest channel any tile offers. It is checked at the end,
	// because a set drawn as solid rock would pass every test above by
	// having no open side at all.
	measured_min := int(TILE_SIZE)

	for b, bi in s.world.biomes.biomes {
		if b.tile_base == TILE_NONE do continue

		for k in 0 ..< wang_set_size(b) {
			id := b.tile_base + Tile_Id(k)
			sig := wang_signature_of(b, id)
			name := s.world.biomes.names[bi]

			if wang_north(sig) == 1 {
				ch := tile_band_channel(s.world.tiles, id, s.world.materials, .North)
				if ch < measured_min do measured_min = ch
				testing.expectf(
					t, ch >= PLAYER_BODY_W + 2,
					"%s tile %d north band: clear channel is %d cells, under PLAYER_BODY_W + 2 (%d)",
					name, id, ch, PLAYER_BODY_W + 2,
				)
			}
			if wang_south(sig) == 1 {
				ch := tile_band_channel(s.world.tiles, id, s.world.materials, .South)
				if ch < measured_min do measured_min = ch
				testing.expectf(
					t, ch >= PLAYER_BODY_W + 2,
					"%s tile %d south band: clear channel is %d cells, under PLAYER_BODY_W + 2 (%d)",
					name, id, ch, PLAYER_BODY_W + 2,
				)
			}
			if wang_east(sig) == 1 {
				ch := tile_band_channel(s.world.tiles, id, s.world.materials, .East)
				if ch < measured_min do measured_min = ch
				testing.expectf(
					t, ch >= PLAYER_BODY_H + 2,
					"%s tile %d east band: clear channel is %d cells, under PLAYER_BODY_H + 2 (%d)",
					name, id, ch, PLAYER_BODY_H + 2,
				)
			}
			if wang_west(sig) == 1 {
				ch := tile_band_channel(s.world.tiles, id, s.world.materials, .West)
				if ch < measured_min do measured_min = ch
				testing.expectf(
					t, ch >= PLAYER_BODY_H + 2,
					"%s tile %d west band: clear channel is %d cells, under PLAYER_BODY_H + 2 (%d)",
					name, id, ch, PLAYER_BODY_H + 2,
				)
			}
		}
	}

	// A set with no open side at all would satisfy every test above by
	// never entering one, and would be a world of sealed boxes.
	testing.expectf(
		t,
		measured_min <= TILE_SIZE - 2 * WANG_SEAM,
		"no tile of any shipped set carries an open edge, so nothing measured a channel",
	)

	// And the world is drawn to him, not merely around him.
	testing.expectf(
		t,
		measured_min >= PLAYER_WORLD_CHANNEL,
		"the narrowest channel in any shipped set is %d cells, under PLAYER_WORLD_CHANNEL (%d): the world has shrunk back to a tunnel",
		measured_min,
		PLAYER_WORLD_CHANNEL,
	)
}
