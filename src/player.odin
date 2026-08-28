package game

import "core:math"
import "core:testing"

Player_Button :: enum u8 {
	Left,
	Right,
	Jump,
	Run,
	Dig,
	Throw,
}

Player_Input :: bit_set[Player_Button; u8]

PLAYER_TICK_HZ :: 60

PLAYER_BODY_W :: 8
PLAYER_BODY_H :: 13

PLAYER_WALK_SPEED       :: 42
PLAYER_RUN_SPEED        :: 74
PLAYER_GROUND_ACCEL     :: 320
PLAYER_AIR_ACCEL        :: 140
PLAYER_GROUND_FRICTION  :: 420
PLAYER_AIR_DRAG         :: 30

PLAYER_GRAVITY    :: 430
PLAYER_JUMP_SPEED :: 155
PLAYER_MAX_FALL   :: 420

PLAYER_JET_ACCEL       :: 880
PLAYER_JET_MAX_RISE    :: 130
PLAYER_JET_DELAY_TICKS :: 6

PLAYER_FUEL_MAX        :: 1.0
PLAYER_JET_DRAIN       :: 0.5
PLAYER_FUEL_ON_GROUND  :: 1.4
PLAYER_FUEL_IN_AIR     :: 0.22

PLAYER_WORLD_CHANNEL :: 3 * PLAYER_BODY_H

PLAYER_COYOTE_TICKS :: 5

PLAYER_JUMP_BUFFER_TICKS :: 6
PLAYER_CLIMB        :: 3
PLAYER_DIG_OUT      :: 24

SPAWN_MOUTH_DEPTH  :: 10
SPAWN_CLEARANCE    :: 12
SPAWN_SEARCH_RANGE :: 4096

PLAYER_DIG_POWER :: 8

PLAYER_DIG_RANGE :: 2 * PLAYER_BODY_H
PLAYER_DIG_WIDTH :: PLAYER_BODY_H + 2

#assert(CUT_SPRAY_NEAR > PLAYER_BODY_H - PLAYER_BODY_H / 2)

PLAYER_AIM_RIGHT :: u8(0)
PLAYER_AIM_DOWN  :: u8(64)
PLAYER_AIM_LEFT  :: u8(128)
PLAYER_AIM_UP    :: u8(192)

player_aim_of :: proc(dx, dy: f32) -> u8 {
	if dx == 0 && dy == 0 do return PLAYER_AIM_RIGHT
	turns := math.atan2(dy, dx) / (2 * math.PI)
	return u8(i32(math.round(turns * 256)) & 255)
}

player_aim_vector :: proc(aim: u8) -> (dx, dy: f32) {
	angle := f32(aim) * (2 * math.PI / 256)
	return math.cos(angle), math.sin(angle)
}

player_aim_facing :: proc(aim: u8) -> i8 {
	return aim <= PLAYER_AIM_DOWN || aim >= PLAYER_AIM_UP ? 1 : -1
}

// THIS ENUM IS A CONTRACT: src/sprite.odin reads it to match wizard.png rows.
Player_Motion :: enum u8 {
	Idle,
	Walk,
	Run,
	Rise,
	Fall,
	Jet,
}

PLAYER_MOTION_IDLE_SPEED :: 3
PLAYER_MOTION_RUN_MARGIN :: 3

player_motion :: proc(p: Player) -> Player_Motion {
	if p.jetting do return .Jet
	if !p.on_ground && p.vy < 0 do return .Rise
	if !p.on_ground do return .Fall

	speed := abs(p.vx)
	if speed < PLAYER_MOTION_IDLE_SPEED do return .Idle
	if speed > PLAYER_WALK_SPEED + PLAYER_MOTION_RUN_MARGIN do return .Run
	return .Walk
}

Player :: struct {
	x, y:   f32,
	vx, vy: f32,
	fuel:   f32,
	anim:   f32,

	coyote:      u8,
	jet_delay:   u8,
	jump_buffer: u8,
	facing:      i8,
	aim:         u8,
	on_ground:   bool,
	jetting:     bool,
	digging:     bool,
}

#assert(size_of(Player) == 32)

player_centre :: proc(p: Player) -> (x, y: i32) {
	return i32(math.floor(p.x)), i32(math.floor(p.y)) - PLAYER_BODY_H / 2
}

Terrain :: struct {
	// A pointer, not the world itself. A terrain is a *view* of a world
	// with a sandbox laid over part of it, and a view that carries a
	// copy of what it views is a snapshot that stops following the
	// world it claims to describe.
	//
	// It is not the speed. Seven hundred and fifty bytes by value into
	// a call made hundreds of thousands of times a frame looks like the
	// cost of the day, and it is not -- measured at -o:speed the two
	// are the same, because the compiler passes a struct that large by
	// reference anyway.
	world:   ^World,
	sandbox: ^Sandbox,
}

terrain_cell_at :: proc(t: Terrain, wx, wy: i32) -> Cell {
	if t.sandbox != nil {
		sx := wx - t.sandbox.origin_x
		sy := wy - t.sandbox.origin_y
		if sandbox_in_bounds(t.sandbox, sx, sy) {
			return sandbox_cell(t.sandbox, sx, sy)
		}
	}
	return world_cell_at(t.world^, wx, wy)
}

player_solid_at :: proc(t: Terrain, x, y: i32) -> bool {
	if t.sandbox != nil {
		sx := x - t.sandbox.origin_x
		sy := y - t.sandbox.origin_y
		if sandbox_in_bounds(t.sandbox, sx, sy) {
			i := sandbox_index(t.sandbox, sx, sy)
			if t.sandbox.moved[i] do return false
			return material_stops_him(&t.world.materials, t.sandbox.cells[i])
		}
	}
	return material_stops_him(&t.world.materials, world_cell_at(t.world^, x, y))
}

// Walks the straight line between two points in steps of at most one cell,
// the way a pot's own flight does, and answers only whether anything solid
// ever stands in the way. See docs/drudge.md, "Sight: seeing him, not just
// standing near him".
terrain_line_clear :: proc(t: Terrain, x0, y0, x1, y1: f32) -> bool {
	dx := x1 - x0
	dy := y1 - y0
	dist := math.sqrt(dx*dx + dy*dy)
	steps := max(i32(math.ceil(dist)), 1)

	sx := dx / f32(steps)
	sy := dy / f32(steps)

	for i in 0 ..= steps {
		x := x0 + sx*f32(i)
		y := y0 + sy*f32(i)
		if player_solid_at(t, i32(math.floor(x)), i32(math.floor(y))) do return false
	}
	return true
}

// By pointer because a table is not a value to hand around, not because
// it is faster: measured both ways over four hundred thousand calls at
// -o:speed there is nothing between them, so the compiler is already
// passing the four hundred and seventy-two bytes by reference.
@(private = "file")
material_stops_him :: proc(table: ^Material_Table, c: Cell) -> bool {
	if int(c) >= len(table.materials) do return false
	state := table.materials[c].state
	return state == .Solid || state == .Powder
}

@(private = "file")
player_body_x_bounds :: proc(x: f32) -> (x0, x1: i32) {
	return i32(math.floor(x - PLAYER_BODY_W * 0.5)), i32(math.floor(x + PLAYER_BODY_W * 0.5))
}

@(private = "file")
player_body_y_bounds :: proc(y: f32) -> (y0, y1: i32) {
	y1 = i32(math.floor(y))
	y0 = y1 - PLAYER_BODY_H
	return
}

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

@(private = "file")
player_on_ground :: proc(t: Terrain, x, y: f32) -> bool {
	x0, x1 := player_body_x_bounds(x)
	_, y1 := player_body_y_bounds(y)
	for cx in x0 ..< x1 {
		if player_solid_at(t, cx, y1) do return true
	}
	return false
}

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

@(private = "file")
player_ceiling_clear :: proc(t: Terrain, x, y: f32) -> bool {
	x0, x1 := player_body_x_bounds(x)
	y0, _ := player_body_y_bounds(y)
	for cx in x0 ..< x1 {
		if player_solid_at(t, cx, y0 - 1) do return false
	}
	return true
}

@(private = "file")
player_settle :: proc(t: Terrain, x: f32, y: ^f32, max_drop: i32) {
	for _ in 0 ..< max_drop {
		if !player_edge_clear_y(t, x, y^ + 1, 1) do break
		y^ += 1
	}
}

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

@(private = "file")
move_toward :: proc(current, target, max_delta: f32) -> f32 {
	if abs(target - current) <= max_delta do return target
	return current + (target > current ? max_delta : -max_delta)
}

PLAYER_JET_LOCKED :: max(u8)

player_step :: proc(p: ^Player, t: Terrain, held: Player_Input, jump_pressed: bool, aim: u8 = PLAYER_AIM_RIGHT) {
	dt : f32 = 1.0 / PLAYER_TICK_HZ

	if !player_body_clear(t, p.x, p.y) {
		for up in i32(1) ..= PLAYER_DIG_OUT {
			ny := p.y - f32(up)
			if player_body_clear(t, p.x, ny) {
				p.y = ny
				break
			}
		}
	}

	on_ground := player_on_ground(t, p.x, p.y)
	can_jump := on_ground || p.coyote > 0

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
		p.facing = player_aim_facing(aim)
	}

	if p.jump_buffer > 0 do p.jump_buffer -= 1
	if jump_pressed do p.jump_buffer = PLAYER_JUMP_BUFFER_TICKS

	if p.jump_buffer > 0 && can_jump {
		p.vy = -PLAYER_JUMP_SPEED
		p.jump_buffer = 0
		p.coyote = 0
		p.jet_delay = PLAYER_JET_DELAY_TICKS
	}

	if on_ground {
		p.coyote = PLAYER_COYOTE_TICKS
	} else if p.coyote > 0 {
		p.coyote -= 1
	}

	thrusting := false
	if .Jump in held && !on_ground {
		if p.jet_delay == PLAYER_JET_LOCKED {
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

		fill : f32 = on_ground ? PLAYER_FUEL_ON_GROUND : PLAYER_FUEL_IN_AIR
		p.fuel = min(p.fuel + fill * dt, PLAYER_FUEL_MAX)
	}

	remaining_x := p.vx * dt
	for remaining_x != 0 {
		d := clamp(remaining_x, -1, 1)
		dir : i32 = d > 0 ? 1 : -1
		nx := p.x + d

		if player_edge_clear_x(t, nx, p.y, dir) {
			p.x = nx
		} else if on_ground && player_climb(t, p, nx, dir) {
		} else {
			p.vx = 0
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
			if dir > 0 do p.y = math.floor(ny)
			p.vy = 0
			break
		}
		remaining_y -= d
	}

	p.on_ground = player_on_ground(t, p.x, p.y)
	p.anim += dt

	p.aim = aim
	p.digging = .Dig in held
	if p.digging do player_dig(p^, t)
}

player_dig :: proc(p: Player, t: Terrain) -> int {
	if t.sandbox == nil do return 0

	dx, dy := player_aim_vector(p.aim)
	wx, wy := player_centre(p)
	return sandbox_cut(
		t.sandbox,
		t.world.materials,
		wx - t.sandbox.origin_x,
		wy - t.sandbox.origin_y,
		dx,
		dy,
		PLAYER_DIG_RANGE,
		PLAYER_DIG_WIDTH / 2,
		PLAYER_DIG_POWER,
	)
}

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

@(private = "file")
world_spawn_fallback :: proc(t: Terrain) -> (x, y: i32, found: bool) {
	surface_row, row_found := world_find_surface_row(t.world^)
	if !row_found do return 0, 0, false

	cpp := t.world.biomes.cells_per_pixel
	surface_y := (surface_row - t.world.biomes.origin_pixel_y) * cpp
	fx, fy := i32(0), surface_y - SPAWN_CLEARANCE

	if !player_body_clear(t, f32(fx), f32(fy)) do return 0, 0, false
	return fx, fy, true
}

// The region the wizard starts in, when the map names one: the nth
// region of the spawn biome, counted west to east along the row it
// lies on. The homelands are six regions of one biome and he starts on
// the fourth of them, so the walk east to the caves is the longer half
// of the village.
@(private = "file")
world_find_spawn_region :: proc(world: World) -> (px, py: i32, found: bool) {
	id := world.biomes.spawn_biome
	if id == BIOME_EMPTY do return 0, 0, false

	m := world.biome_map
	seen := i32(0)
	for y in 0 ..< m.height {
		for x in 0 ..< m.width {
			if biome_map_at(m, x, y) != id do continue
			seen += 1
			if seen == world.biomes.spawn_region do return x, y, true
		}
	}
	return 0, 0, false
}

// The first standing place under the open sky in one column: the first
// solid cell going down, if a body fits above it. A column that starts
// buried has no standing place at all and is not one to search past,
// because everything under it is inside the ground.
@(private = "file")
world_ground_in_column :: proc(t: Terrain, x, top, height: i32) -> (y: i32, found: bool) {
	for cy in top ..< top + height {
		if !player_solid_at(t, x, cy) do continue
		if !player_body_clear(t, f32(x), f32(cy)) do return 0, false
		return cy, true
	}
	return 0, false
}

// Out from the middle of the region, so the yard the picture keeps
// clear in the middle is what he lands in, and a house he would
// otherwise stand on the roof of moves him aside instead.
@(private = "file")
world_find_ground_in_region :: proc(t: Terrain, px, py: i32) -> (x, y: i32, found: bool) {
	cpp := t.world.biomes.cells_per_pixel
	left := (px - t.world.biomes.origin_pixel_x) * cpp
	top := (py - t.world.biomes.origin_pixel_y) * cpp
	middle := left + cpp / 2

	for dist in i32(0) ..< cpp / 2 {
		for side in ([2]i32{1, -1}) {
			cx := middle + side * dist
			if cy, ok := world_ground_in_column(t, cx, top, cpp); ok do return cx, cy, true
			if dist == 0 do break
		}
	}
	return 0, 0, false
}

world_find_spawn :: proc(world: ^World) -> (x, y: i32, found: bool) {
	t := Terrain{world = world}

	if px, py, region_found := world_find_spawn_region(world^); region_found {
		if gx, gy, ground_found := world_find_ground_in_region(t, px, py); ground_found {
			return gx, gy, true
		}
	}

	surface_row, row_found := world_find_surface_row(world^)
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

player_spawn :: proc(world: ^World) -> Player {
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

@(private = "file")
carve_open_floor :: proc(world: World, floor_row: i32) {
	for y in i32(0) ..< floor_row {
		for x in i32(0) ..< world.biome_map.width do biome_map_set(world.biome_map, x, y, PLAYER_TEST_AIR)
	}
}

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
	terrain := Terrain{world = &world}

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
	for y in i32(0) ..< 20 {
		for x in i32(60) ..< 70 do biome_map_set(world.biome_map, x, y, PLAYER_TEST_ROCK)
	}
	terrain := Terrain{world = &world}

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
	for y in i32(0) ..< 2000 {
		for x in i32(15) ..< 25 do biome_map_set(world.biome_map, x, y, PLAYER_TEST_ROCK)
	}
	terrain := Terrain{world = &world}

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
	terrain := Terrain{world = &world}

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
	terrain := Terrain{world = &world}

	p := Player{x = 20, y = 150, facing = 1}
	start_y := p.y
	min_y := p.y

	player_step(&p, terrain, {.Jump}, true)
	min_y = min(min_y, p.y)
	for _ in 0 ..< 300 {
		player_step(&p, terrain, {}, false)
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
	terrain := Terrain{world = &world}

	p := Player{x = 10, y = 10, vy = 50, facing = 1}
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

	for y in i32(0) ..< 20 {
		for x in i32(0) ..< 100 do biome_map_set(world.biome_map, x, y, PLAYER_TEST_AIR)
	}
	for y in i32(20) ..< 250 {
		for x in i32(40) ..< 100 do biome_map_set(world.biome_map, x, y, PLAYER_TEST_AIR)
	}
	terrain := Terrain{world = &world}

	p := Player{x = 30, y = 20, facing = 1}
	for _ in 0 ..< 500 {
		player_step(&p, terrain, {.Right}, false)
		if !p.on_ground do break
	}

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
		terrain := Terrain{world = &world}

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
		terrain := Terrain{world = &world}

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
	for y in i32(4) ..< 20 - PLAYER_CLIMB {
		for x in i32(50) ..< 120 do biome_map_set(world.biome_map, x, y, PLAYER_TEST_AIR)
	}
	terrain := Terrain{world = &world}

	p := Player{x = 30, y = 20, facing = 1}
	for _ in 0 ..< 300 do player_step(&p, terrain, {.Right}, false)

	testing.expectf(t, i32(math.floor(p.y)) == 20, "a refused climb must leave him on the lower floor, got y=%f", p.y)
	testing.expect(t, p.vx == 0, "the wall must stop him rather than wedge him in rock")
	testing.expect(t, player_body_clear(terrain, p.x, p.y), "he must not end up inside rock")
}

@(test)
test_the_jetpack_lifts_him_drains_the_tank_and_he_falls_when_empty :: proc(t: ^testing.T) {
	world, ok := make_flat_world(t, 40, 20000)
	if !ok do return
	defer destroy_flat_world(world)
	carve_all_air(world)
	terrain := Terrain{world = &world}

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
	ground_terrain := Terrain{world = &ground_world}

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
	air_terrain := Terrain{world = &air_world}

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

	for y in i32(0) ..< 200 {
		for x in i32(0) ..< 60 do biome_map_set(world.biome_map, x, y, PLAYER_TEST_AIR)
	}
	buried_y := i32(200) + PLAYER_DIG_OUT
	terrain := Terrain{world = &world}

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
	terrain := Terrain{world = &world}

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

	terrain := Terrain{world = &world, sandbox = &sb}

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
	for y in i32(0) ..< sb.height {
		for x in i32(0) ..< sb.width {
			sb.cells[sandbox_index(&sb, x, y)] = y >= 40 ? Cell(sand) : MATERIAL_AIR
		}
	}

	terrain_no_sandbox := Terrain{world = &world}
	terrain_with_sandbox := Terrain{world = &world, sandbox = &sb}

	px := f32(sb.origin_x + 32)
	py := f32(sb.origin_y + 40)

	without := Player{x = px, y = py - 5, facing = 1}
	for _ in 0 ..< 300 do player_step(&without, terrain_no_sandbox, {}, false)
	testing.expect(t, !without.on_ground, "with no sandbox there is nothing under him: he must still be falling")

	with := Player{x = px, y = py - 5, facing = 1}
	for _ in 0 ..< 300 do player_step(&with, terrain_with_sandbox, {}, false)
	testing.expect(t, with.on_ground, "the sandbox's sand must hold him up, though the world under it is empty air")
	testing.expectf(t, i32(math.floor(with.y)) == sb.origin_y + 40, "he must land on the sand row, got y=%f", with.y)
}

@(test)
test_digging_the_floor_out_from_under_him_makes_him_fall :: proc(t: ^testing.T) {
	world, ok := make_flat_world(t, 200, 200)
	if !ok do return
	defer destroy_flat_world(world)
	carve_open_floor(world, 100)

	sb, sb_ok := sandbox_make(64, 64, 1)
	if !testing.expect(t, sb_ok, "the sandbox must open") do return
	defer sandbox_destroy(&sb)
	sandbox_fill_from_world(&sb, world, 40, 70)

	terrain := Terrain{world = &world, sandbox = &sb}

	p := Player{x = 72, y = 100, facing = 1}
	for _ in 0 ..< 10 do player_step(&p, terrain, {}, false)
	testing.expect(t, p.on_ground, "he must be standing on the sandbox's copy of the rock floor first")

	sandbox_dig(&sb, world.materials, 32, 30, 6, 255)

	for _ in 0 ..< 5 do player_step(&p, terrain, {}, false)
	testing.expect(t, !p.on_ground, "the floor is gone from the sandbox: he must fall through it")
	testing.expectf(t, p.vy > 0, "gravity must be pulling him down through the hole, got vy=%f", p.vy)
}

@(private = "file")
dig_test_sandbox :: proc(t: ^testing.T, world: World, p: Player, name: string) -> (sb: Sandbox, ok: bool) {
	material, found := find_material_index(world.materials, name)
	if !testing.expectf(t, found, "%s must exist in the material table", name) do return {}, false

	sb, ok = sandbox_make(128, 128, 1)
	if !testing.expect(t, ok, "the sandbox must open") do return {}, false

	cx, cy := player_centre(p)
	sb.origin_x = cx - 64
	sb.origin_y = cy - 64
	for i in 0 ..< len(sb.cells) do sb.cells[i] = Cell(material)
	return sb, true
}

@(test)
test_the_digger_cuts_along_the_aim_and_not_along_his_facing :: proc(t: ^testing.T) {
	world, ok := make_flat_world(t, 200, 60)
	if !ok do return
	defer destroy_flat_world(world)
	carve_all_air(world)

	p := Player{x = 100, y = 30, facing = 1, aim = PLAYER_AIM_UP}
	sb, sb_ok := dig_test_sandbox(t, world, p, "Rock")
	if !sb_ok do return
	defer sandbox_destroy(&sb)

	rock := sandbox_cell(&sb, 0, 0)
	terrain := Terrain{world = &world, sandbox = &sb}
	removed := player_dig(p, terrain)
	testing.expect(t, removed > 0, "the beam must remove something")

	cx, cy := player_centre(p)
	sx := cx - sb.origin_x
	sy := cy - sb.origin_y

	for step in i32(1) ..= PLAYER_DIG_RANGE {
		testing.expectf(
			t, sandbox_cell(&sb, sx, sy - step) != rock,
			"the beam aimed up must clear the cell %d above his chest", step,
		)
	}
	ahead := sx + PLAYER_DIG_WIDTH
	testing.expect(
		t, sandbox_cell(&sb, ahead, sy) == rock,
		"an aim of up must leave the ground in front of his facing alone",
	)
}

@(test)
test_the_kerf_is_wide_enough_for_his_body :: proc(t: ^testing.T) {
	world, ok := make_flat_world(t, 200, 60)
	if !ok do return
	defer destroy_flat_world(world)
	carve_all_air(world)

	p := Player{x = 100, y = 30, facing = 1, aim = PLAYER_AIM_RIGHT}
	sb, sb_ok := dig_test_sandbox(t, world, p, "Rock")
	if !sb_ok do return
	defer sandbox_destroy(&sb)

	rock := sandbox_cell(&sb, 0, 0)
	terrain := Terrain{world = &world, sandbox = &sb}
	player_dig(p, terrain)

	cx, cy := player_centre(p)
	sx := cx - sb.origin_x + PLAYER_DIG_RANGE / 2
	sy := cy - sb.origin_y

	clear_cells := 0
	for y in sy - PLAYER_DIG_WIDTH ..= sy + PLAYER_DIG_WIDTH {
		if sandbox_cell(&sb, sx, y) != rock do clear_cells += 1
	}
	testing.expectf(
		t, clear_cells == PLAYER_DIG_WIDTH,
		"the kerf must be PLAYER_DIG_WIDTH (%d) cells across, got %d", PLAYER_DIG_WIDTH, clear_cells,
	)
	testing.expectf(
		t, PLAYER_DIG_WIDTH > PLAYER_BODY_H,
		"the kerf must be wider than the body is tall, or he cannot enter his own tunnel",
	)
}

@(test)
test_the_digger_stops_at_what_it_cannot_cut :: proc(t: ^testing.T) {
	world, ok := make_flat_world(t, 200, 60)
	if !ok do return
	defer destroy_flat_world(world)
	carve_all_air(world)

	p := Player{x = 100, y = 30, facing = 1, aim = PLAYER_AIM_RIGHT}
	sb, sb_ok := dig_test_sandbox(t, world, p, "Rock")
	if !sb_ok do return
	defer sandbox_destroy(&sb)

	rock := sandbox_cell(&sb, 0, 0)
	bedrock, bedrock_found := find_material_index(world.materials, "Bedrock")
	if !testing.expect(t, bedrock_found, "Bedrock must exist in the material table") do return

	cx, cy := player_centre(p)
	sx := cx - sb.origin_x
	sy := cy - sb.origin_y

	wall := sx + PLAYER_DIG_RANGE / 2
	for y in i32(0) ..< sb.height do sb.cells[sandbox_index(&sb, wall, y)] = Cell(bedrock)

	terrain := Terrain{world = &world, sandbox = &sb}
	player_dig(p, terrain)

	testing.expect(
		t, sandbox_cell(&sb, wall, sy) == Cell(bedrock),
		"bedrock is harder than PLAYER_DIG_POWER: the beam must not remove it",
	)
	testing.expect(
		t, sandbox_cell(&sb, wall + 1, sy) == rock,
		"the beam must stop at the bedrock, not reach past it",
	)
	testing.expect(
		t, sandbox_cell(&sb, wall - 1, sy) != rock,
		"everything short of the bedrock must still be cut",
	)
}

@(test)
test_the_digger_throws_its_cuttings_back_down_the_hole :: proc(t: ^testing.T) {
	world, ok := make_flat_world(t, 200, 60)
	if !ok do return
	defer destroy_flat_world(world)
	carve_all_air(world)

	p := Player{x = 100, y = 30, facing = 1, aim = PLAYER_AIM_RIGHT}
	sb, sb_ok := dig_test_sandbox(t, world, p, "Rock")
	if !sb_ok do return
	defer sandbox_destroy(&sb)

	gravel, gravel_found := find_material_index(world.materials, "Gravel")
	if !testing.expect(t, gravel_found, "Gravel must exist in the material table") do return

	terrain := Terrain{world = &world, sandbox = &sb}
	removed := player_dig(p, terrain)
	testing.expect(t, removed > 0, "the beam must cut the rock: rock is exactly PLAYER_DIG_POWER")

	counts := make([]int, len(world.materials.materials))
	defer delete(counts)
	sandbox_census(&sb, counts)

	testing.expect(t, counts[gravel] > 0, "some of the cut rock must fly as gravel")
	testing.expectf(
		t, counts[gravel] < removed / 2,
		"most of the cut must be vapour, or the tunnel fills as fast as it opens: %d grains of %d cells cut",
		counts[gravel], removed,
	)
}

@(test)
test_a_thrown_grain_is_something_that_can_fall :: proc(t: ^testing.T) {
	world, ok := make_flat_world(t, 200, 60)
	if !ok do return
	defer destroy_flat_world(world)

	table := world.materials
	for _, i in table.materials {
		debris := table.crumbles_to[i]
		if table.kind[debris] == .Still do continue
		testing.expectf(
			t, table.materials[debris].state != .Solid,
			"%s crumbles into %s, which a cut would throw: a thrown grain must not be solid",
			table.names[i], table.names[debris],
		)
	}
}

@(test)
test_holding_dig_cuts_the_sandbox_where_the_aim_points :: proc(t: ^testing.T) {
	world, ok := make_flat_world(t, 200, 60)
	if !ok do return
	defer destroy_flat_world(world)
	carve_open_floor(world, 30)

	p := Player{x = 100, y = 30, facing = 1}
	sb, sb_ok := dig_test_sandbox(t, world, p, "Rock")
	if !sb_ok do return
	defer sandbox_destroy(&sb)

	rock := sandbox_cell(&sb, 0, 0)
	terrain := Terrain{world = &world, sandbox = &sb}

	cx, cy := player_centre(p)
	sx := cx - sb.origin_x
	sy := cy - sb.origin_y
	testing.expect(t, sandbox_cell(&sb, sx - PLAYER_DIG_RANGE, sy) == rock, "the cell he aims at must start as rock")

	player_step(&p, terrain, {.Dig}, false, PLAYER_AIM_LEFT)

	testing.expect(t, p.digging, "the window needs to know the beam is on, to draw it")
	testing.expectf(t, p.aim == PLAYER_AIM_LEFT, "player_step must keep the aim it was given, got %d", p.aim)
	testing.expect(t, p.facing == -1, "standing still, he must turn to hold the aim")
	testing.expect(
		t, sandbox_cell(&sb, sx - PLAYER_DIG_RANGE / 2, sy) != rock,
		"holding Dig must cut along the aim it was given",
	)
}

@(test)
test_an_aim_round_trips_through_its_byte_of_turn :: proc(t: ^testing.T) {
	cases := []struct{dx, dy: f32, aim: u8, name: string} {
		{1, 0, PLAYER_AIM_RIGHT, "right"},
		{0, 1, PLAYER_AIM_DOWN, "down"},
		{-1, 0, PLAYER_AIM_LEFT, "left"},
		{0, -1, PLAYER_AIM_UP, "up"},
	}
	for c in cases {
		testing.expectf(t, player_aim_of(c.dx, c.dy) == c.aim, "%s must read as aim %d", c.name, c.aim)
		dx, dy := player_aim_vector(c.aim)
		testing.expectf(
			t, abs(dx-c.dx) < 0.001 && abs(dy-c.dy) < 0.001,
			"aim %d must point back along %s, got %f, %f", c.aim, c.name, dx, dy,
		)
	}

	testing.expect(t, player_aim_of(0, 0) == PLAYER_AIM_RIGHT, "no direction at all must read as right")
	testing.expect(t, player_aim_facing(PLAYER_AIM_RIGHT) == 1)
	testing.expect(t, player_aim_facing(PLAYER_AIM_LEFT) == -1)
	testing.expect(t, player_aim_facing(PLAYER_AIM_LEFT - 32) == -1, "the left half of the circle faces left")
	testing.expect(t, player_aim_facing(PLAYER_AIM_UP + 32) == 1, "the right half of the circle faces right")
}

@(test)
test_a_jump_pressed_just_before_he_lands_is_not_thrown_away :: proc(t: ^testing.T) {
	world, ok := make_flat_world(t, 40, 200)
	if !ok do return
	defer destroy_flat_world(world)
	carve_open_floor(world, 150)
	terrain := Terrain{world = &world}

	falling := Player{x = 20, y = 100, facing = 1}
	for _ in 0 ..< 200 {
		player_step(&falling, terrain, {}, false)
		if falling.on_ground do break
	}
	if !testing.expect(t, falling.on_ground, "he must reach the floor with no input at all") do return

	land_tick := 0
	drop := Player{x = 20, y = 100, facing = 1}
	for !drop.on_ground && land_tick < 200 {
		player_step(&drop, terrain, {}, false)
		land_tick += 1
	}

	first_failing_early := -1
	for early in 0 ..= int(PLAYER_JUMP_BUFFER_TICKS) + 3 {
		trial := Player{x = 20, y = 100, facing = 1}
		press_at := land_tick - early
		jumped := false
		for tick in 0 ..< land_tick + 8 {
			player_step(&trial, terrain, {}, tick == press_at)
			if trial.vy < 0 do jumped = true
		}
		if !jumped && first_failing_early == -1 do first_failing_early = early
	}

	testing.expectf(
		t,
		first_failing_early == int(PLAYER_JUMP_BUFFER_TICKS),
		"a press must survive PLAYER_JUMP_BUFFER_TICKS ticks and no more, but it was forgotten after %d",
		first_failing_early,
	)
}

@(test)
test_the_jump_buffer_changes_nothing_about_a_jump_from_the_ground :: proc(t: ^testing.T) {
	world, ok := make_flat_world(t, 40, 200)
	if !ok do return
	defer destroy_flat_world(world)
	carve_open_floor(world, 150)
	terrain := Terrain{world = &world}

	p := Player{x = 20, y = 150, facing = 1}
	player_step(&p, terrain, {.Jump}, true)

	want := f32(-PLAYER_JUMP_SPEED) + f32(PLAYER_GRAVITY)/f32(PLAYER_TICK_HZ)
	testing.expectf(
		t, abs(p.vy - want) < 0.01,
		"the launch must be PLAYER_JUMP_SPEED with one tick of gravity on it, %f, got %f", want, p.vy,
	)
	testing.expect(t, p.jump_buffer == 0, "a press spent on the tick it arrived must leave nothing behind")
}

@(test)
test_a_falling_grain_is_not_a_floor_and_a_landed_one_is :: proc(t: ^testing.T) {
	world, ok := make_flat_world(t, 200, 60)
	if !ok do return
	defer destroy_flat_world(world)
	carve_all_air(world)

	sand, sand_found := find_material_index(world.materials, "Sand")
	rock, rock_found := find_material_index(world.materials, "Rock")
	if !testing.expect(t, sand_found && rock_found, "Sand and Rock must exist") do return

	sb, sb_ok := sandbox_make(32, 64, 1)
	if !testing.expect(t, sb_ok, "the sandbox must open") do return
	defer sandbox_destroy(&sb)

	floor_row := i32(40)
	for x in i32(0) ..< sb.width do sandbox_paint(&sb, world.materials, x, floor_row, 0, Cell(rock))
	sandbox_paint(&sb, world.materials, 16, 4, 0, Cell(sand))

	terrain := Terrain{world = &world, sandbox = &sb}

	sandbox_step(&sb, world.materials)
	grain_y := i32(-1)
	for y in i32(0) ..< floor_row {
		if sandbox_cell(&sb, 16, y) == Cell(sand) do grain_y = y
	}
	if !testing.expect(t, grain_y > 4, "the grain must have fallen at least one cell") do return
	testing.expect(
		t, !player_solid_at(terrain, 16, grain_y),
		"a grain that moved on the last tick must not hold him up",
	)

	for _ in 0 ..< 64 do sandbox_step(&sb, world.materials)
	testing.expect(
		t, sandbox_cell(&sb, 16, floor_row - 1) == Cell(sand),
		"the grain must come to rest on the floor",
	)
	testing.expect(
		t, player_solid_at(terrain, 16, floor_row - 1),
		"the same grain, at rest, must hold him up again",
	)
	testing.expect(
		t, player_solid_at(terrain, 16, floor_row),
		"and the rock under it never moved at all",
	)
}

@(test)
test_he_crosses_a_grain_that_is_falling_and_stops_at_one_that_has_landed :: proc(t: ^testing.T) {
	world, ok := make_flat_world(t, 200, 60)
	if !ok do return
	defer destroy_flat_world(world)
	carve_all_air(world)

	sand, sand_found := find_material_index(world.materials, "Sand")
	if !testing.expect(t, sand_found, "Sand must exist") do return

	start := Player{x = 40, y = 40, vx = PLAYER_RUN_SPEED, facing = 1}
	grain_x := i32(start.x) + PLAYER_BODY_W/2
	_, chest := player_centre(start)

	falling_sb, falling_ok := sandbox_make(128, 128, 1)
	if !testing.expect(t, falling_ok, "the sandbox must open") do return
	defer sandbox_destroy(&falling_sb)
	sandbox_paint(&falling_sb, world.materials, grain_x, chest, 0, Cell(sand))
	sandbox_step(&falling_sb, world.materials)

	falling := start
	player_step(&falling, Terrain{world = &world, sandbox = &falling_sb}, {.Right, .Run}, false)

	landed_sb, landed_ok := sandbox_make(128, 128, 1)
	if !testing.expect(t, landed_ok, "the sandbox must open") do return
	defer sandbox_destroy(&landed_sb)
	for y in i32(0) ..< landed_sb.height {
		if sandbox_cell(&falling_sb, grain_x, y) != Cell(sand) do continue
		sandbox_paint(&landed_sb, world.materials, grain_x, y, 0, Cell(sand))
	}

	landed := start
	player_step(&landed, Terrain{world = &world, sandbox = &landed_sb}, {.Right, .Run}, false)

	testing.expectf(
		t, falling.x > start.x,
		"a grain still in the air must not stop him: he moved to %f from %f", falling.x, start.x,
	)
	testing.expectf(
		t, landed.x == start.x,
		"the same grain at rest must stop him where he stood: he moved to %f from %f", landed.x, start.x,
	)
	testing.expect(t, landed.vx == 0, "and a wall clears the velocity of the axis it stops")
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

	terrain := Terrain{world = &s.world}

	x, y, found := world_find_spawn(&s.world)
	if !testing.expect(t, found, "the shipped map must offer a spawn point") do return

	testing.expect(t, player_solid_at(terrain, x, y), "the feet must be on solid ground")
	testing.expect(t, player_body_clear(terrain, f32(x), f32(y)), "the whole body box must be clear")

	// The map names the biome and the region he starts in, and the
	// shipped map says the fourth of the homelands.
	spawn_biome := s.world.biomes.spawn_biome
	if !testing.expect(t, spawn_biome != BIOME_EMPTY, "the shipped map must name a spawn biome") do return
	testing.expectf(
		t, world_biome_at(s.world, x, y) == spawn_biome,
		"he must stand in %s, and %d,%d is %s",
		s.world.biomes.names[spawn_biome], x, y,
		s.world.biomes.names[world_biome_at(s.world, x, y)],
	)

	cpp := s.world.biomes.cells_per_pixel
	seen := i32(0)
	region_x := i32(0)
	for py in 0 ..< s.world.biome_map.height {
		for px in 0 ..< s.world.biome_map.width {
			if biome_map_at(s.world.biome_map, px, py) != spawn_biome do continue
			seen += 1
			if seen == s.world.biomes.spawn_region do region_x = px
		}
	}
	testing.expectf(
		t, seen == HOMELANDS_REGIONS,
		"the homelands are %d regions long, and the map holds %d", HOMELANDS_REGIONS, seen,
	)

	left := (region_x - s.world.biomes.origin_pixel_x) * cpp
	testing.expectf(
		t, x >= left && x < left + cpp,
		"he must stand in region %d, which is x %d to %d, and he is at %d",
		s.world.biomes.spawn_region, left, left + cpp - 1, x,
	)

	// And in the middle of it, not at one end: the middle is the yard
	// every picture keeps clear for him.
	middle := left + cpp/2
	testing.expectf(
		t, abs(x - middle) < cpp/8,
		"he must land near the middle of the region, at %d against %d", x, middle,
	)
}

@(test)
test_a_fresh_wizard_stands_where_he_spawned :: proc(t: ^testing.T) {
	s: Sim
	if !testing.expect(t, sim_load(&s) == .None, "the world must load") do return
	defer sim_unload(&s)

	terrain := Terrain{world = &s.world}
	p := player_spawn(&s.world)
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

@(private = "file")
tile_band_channel :: proc(set: Tile_Set, id: Tile_Id, materials: Material_Table, side: Wang_Band) -> int {
	is_clear :: proc(set: Tile_Set, id: Tile_Id, materials: Material_Table, x, y: i32) -> bool {
		c := tile_at(set, id, x, y)
		if int(c) >= len(materials.materials) do return false
		state := materials.materials[c].state
		return state != .Solid && state != .Powder
	}

	longest, run := 0, 0
	count :: proc(open: bool, longest, run: ^int) {
		run^ = open ? run^ + 1 : 0
		if run^ > longest^ do longest^ = run^
	}

	switch side {
	case .North, .South:
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

@(test)
test_the_player_fits_the_world :: proc(t: ^testing.T) {
	s: Sim
	if !testing.expect(t, sim_load(&s) == .None, "the world must load") do return
	defer sim_unload(&s)

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

	testing.expectf(
		t,
		measured_min <= TILE_SIZE - 2 * WANG_SEAM,
		"no tile of any shipped set carries an open edge, so nothing measured a channel",
	)

	testing.expectf(
		t,
		measured_min >= PLAYER_WORLD_CHANNEL,
		"the narrowest channel in any shipped set is %d cells, under PLAYER_WORLD_CHANNEL (%d): the world has shrunk back to a tunnel",
		measured_min,
		PLAYER_WORLD_CHANNEL,
	)
}
