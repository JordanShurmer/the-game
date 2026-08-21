package game

import "core:math"
import "core:testing"
import rl "vendor:raylib"

DRUDGE_MAX     :: 4    // drudges the bag can ever hold
DRUDGE_BODY_W  :: 10   // cells, what collides
DRUDGE_BODY_H  :: 12   // cells, what collides
DRUDGE_WALK_SPEED :: 22.0  // cells per second on patrol

DRUDGE_PATROL_LEG  :: 60   // cells walked before the leash turns him anyway
DRUDGE_SIGHT_RANGE :: 140  // cells, centre to centre
DRUDGE_ALERT_HOLD  :: 30   // ticks his sight of the player is remembered after it breaks

DRUDGE_THROW_INTERVAL :: 240   // ticks between throws, 4 seconds at PLAYER_TICK_HZ
#assert(DRUDGE_THROW_INTERVAL == 4 * PLAYER_TICK_HZ)

DRUDGE_THROW_SPEED :: 110.0  // cells per second, along the aim
DRUDGE_THROW_LOB   :: 70.0   // cells per second of lift

DRUDGE_SPAWN_X_OFFSET :: 220  // cells right of the wizard's own spawn

DRUDGE_BODY      :: rl.Color{60, 48, 40, 255}
DRUDGE_BODY_DARK :: rl.Color{34, 26, 22, 255}

// A drudge is a position, a fall speed, how far he has walked this leg,
// which way he is walking, whether he is on the ground, how many ticks he
// still remembers seeing the player, and how many ticks until he may throw
// again. See docs/drudge.md, "He is a fixed bag, like the pots he throws".
Drudge :: struct {
	x, y:           f32,
	vy:             f32,
	walked:         f32,
	dir:            i8,
	on_ground:      bool,
	sight:          u8,
	throw_cooldown: u8,
}
#assert(size_of(Drudge) == 20)

Drudge_Bag :: struct {
	drudges: [DRUDGE_MAX]Drudge,
	count:   i32,
}

@(private = "file")
drudge_x_bounds :: proc(x: f32) -> (x0, x1: i32) {
	return i32(math.floor(x - DRUDGE_BODY_W * 0.5)), i32(math.floor(x + DRUDGE_BODY_W * 0.5))
}

@(private = "file")
drudge_y_bounds :: proc(y: f32) -> (y0, y1: i32) {
	y1 = i32(math.floor(y))
	y0 = y1 - DRUDGE_BODY_H
	return
}

@(private = "file")
drudge_body_clear :: proc(t: Terrain, x, y: f32) -> bool {
	x0, x1 := drudge_x_bounds(x)
	y0, y1 := drudge_y_bounds(y)
	for cy in y0 ..< y1 {
		for cx in x0 ..< x1 {
			if player_solid_at(t, cx, cy) do return false
		}
	}
	return true
}

@(private = "file")
drudge_on_ground :: proc(t: Terrain, x, y: f32) -> bool {
	x0, x1 := drudge_x_bounds(x)
	_, y1 := drudge_y_bounds(y)
	for cx in x0 ..< x1 {
		if player_solid_at(t, cx, y1) do return true
	}
	return false
}

// The cell at his leading edge, over his whole body height, so a wall he is
// walking into turns him before he ever steps inside it.
@(private = "file")
drudge_edge_clear_x :: proc(t: Terrain, x, y: f32, dir: i32) -> bool {
	x0, x1 := drudge_x_bounds(x)
	y0, y1 := drudge_y_bounds(y)
	edge := dir > 0 ? x1 : x0 - 1
	for cy in y0 ..< y1 {
		if player_solid_at(t, edge, cy) do return false
	}
	return true
}

// One step past the leading edge, at the foot row and the row below it. Both
// open means the ground he is walking on is about to run out.
@(private = "file")
drudge_cliff_ahead :: proc(t: Terrain, x, y: f32, dir: i32) -> bool {
	x0, x1 := drudge_x_bounds(x)
	_, y1 := drudge_y_bounds(y)
	edge := dir > 0 ? x1 + 1 : x0 - 2
	return !player_solid_at(t, edge, y1) && !player_solid_at(t, edge, y1 + 1)
}

drudge_centre :: proc(d: Drudge) -> (x, y: i32) {
	return i32(math.floor(d.x)), i32(math.floor(d.y)) - DRUDGE_BODY_H / 2
}

// He faces the player he sees; otherwise he faces the way he is walking.
// This is only ever used for drawing: it changes nothing about his patrol.
drudge_facing :: proc(d: Drudge, player: Player) -> i8 {
	if d.sight == 0 do return d.dir
	return player.x >= d.x ? 1 : -1
}

// Range, the half he is walking toward, and a clear line to him. See
// docs/drudge.md, "Sight: seeing him, not just standing near him".
@(private = "file")
drudge_sees_player :: proc(t: Terrain, d: Drudge, player: Player) -> bool {
	dcx, dcy := drudge_centre(d)
	pcx, pcy := player_centre(player)

	dx := f32(pcx - dcx)
	dy := f32(pcy - dcy)
	if dx*dx+dy*dy > DRUDGE_SIGHT_RANGE*DRUDGE_SIGHT_RANGE do return false

	if (player.x-d.x)*f32(d.dir) <= 0 do return false

	return terrain_line_clear(t, f32(dcx), f32(dcy), f32(pcx), f32(pcy))
}

drudge_place :: proc(world: World, near_x, near_y: i32) -> (bag: Drudge_Bag) {
	t := Terrain{world = world}

	for dy in i32(0) ..< SPAWN_SEARCH_RANGE {
		y := near_y + dy
		if !drudge_body_clear(t, f32(near_x), f32(y)) do continue
		if !drudge_on_ground(t, f32(near_x), f32(y)) do continue

		bag.drudges[0] = Drudge{x = f32(near_x), y = f32(y), dir = 1, on_ground = true}
		bag.count = 1
		return
	}
	return
}

// Aim from the drudge's own centre to the player's, softer and slower than
// the wizard's own throw. See docs/drudge.md, "Throwing: gentler than the
// wizard's own hand".
drudge_throw :: proc(bag: ^Pot_Bag, d: Drudge, player: Player) -> bool {
	dcx, dcy := drudge_centre(d)
	pcx, pcy := player_centre(player)

	dx := f32(pcx - dcx)
	dy := f32(pcy - dcy)
	dist := math.sqrt(dx*dx + dy*dy)
	if dist == 0 do return false

	ax := dx / dist
	ay := dy / dist
	reach := f32(DRUDGE_BODY_W)*0.5 + 2

	return pot_launch(
		bag,
		f32(dcx) + ax*reach, f32(dcy) + ay*reach,
		ax*DRUDGE_THROW_SPEED, ay*DRUDGE_THROW_SPEED-DRUDGE_THROW_LOB,
	)
}

@(private = "file")
drudge_fall :: proc(d: ^Drudge, t: Terrain, dt: f32) {
	remaining := d.vy * dt
	for remaining != 0 {
		step := clamp(remaining, -1, 1)
		ny := d.y + step

		if !drudge_body_clear(t, d.x, ny) {
			d.y = math.floor(ny)
			d.vy = 0
			break
		}
		d.y = ny
		remaining -= step
	}
}

@(private = "file")
drudge_move_x :: proc(d: ^Drudge, t: Terrain, dt: f32) {
	remaining := f32(d.dir) * DRUDGE_WALK_SPEED * dt
	for remaining != 0 {
		step := clamp(remaining, -1, 1)
		dir: i32 = step > 0 ? 1 : -1
		nx := d.x + step

		if !drudge_edge_clear_x(t, nx, d.y, dir) do break
		d.x = nx
		d.walked += abs(step)
		remaining -= step
	}
}

drudge_step :: proc(bag: ^Drudge_Bag, pots: ^Pot_Bag, t: Terrain, player: Player) {
	dt: f32 = 1.0 / PLAYER_TICK_HZ

	for i in 0 ..< int(bag.count) {
		d := &bag.drudges[i]

		d.vy = min(d.vy+PLAYER_GRAVITY*dt, PLAYER_MAX_FALL)
		drudge_fall(d, t, dt)

		if drudge_sees_player(t, d^, player) {
			d.sight = DRUDGE_ALERT_HOLD
		} else if d.sight > 0 {
			d.sight -= 1
		}

		if d.throw_cooldown > 0 do d.throw_cooldown -= 1
		if d.throw_cooldown == 0 && d.sight > 0 {
			if drudge_throw(pots, d^, player) do d.throw_cooldown = DRUDGE_THROW_INTERVAL
		}

		dir := i32(d.dir)
		if !drudge_edge_clear_x(t, d.x, d.y, dir) {
			d.dir = -d.dir
			d.walked = 0
		} else if d.on_ground && drudge_cliff_ahead(t, d.x, d.y, dir) {
			d.dir = -d.dir
			d.walked = 0
		} else if d.walked >= DRUDGE_PATROL_LEG {
			d.dir = -d.dir
			d.walked = 0
		}

		drudge_move_x(d, t, dt)
		d.on_ground = drudge_on_ground(t, d.x, d.y)
	}
}

@(private = "file")
Drudge_Test :: struct {
	table: Material_Table,
	world: World,
	sb:    Sandbox,
}

@(private = "file")
drudge_test_setup :: proc(t: ^testing.T) -> (dt: Drudge_Test, ok: bool) {
	table, load_ok := load_materials("data/materials.txt")
	if !testing.expect(t, load_ok, "materials must load") do return {}, false

	sb, make_ok := sandbox_make(320, 200, 1)
	if !testing.expect(t, make_ok, "the sandbox must open") do return {}, false

	drudge_fill_box(&sb, 0, 0, 319, 199, MATERIAL_AIR)
	return Drudge_Test{table = table, world = World{materials = table}, sb = sb}, true
}

@(private = "file")
drudge_test_destroy :: proc(dt: ^Drudge_Test) {
	sandbox_destroy(&dt.sb)
	destroy_material_table(dt.table)
}

@(private = "file")
drudge_fill_box :: proc(sb: ^Sandbox, x0, y0, x1, y1: i32, c: Cell) {
	for y in y0 ..= y1 {
		for x in x0 ..= x1 {
			if !sandbox_in_bounds(sb, x, y) do continue
			sb.cells[sandbox_index(sb, x, y)] = c
		}
	}
}

@(private = "file")
drudge_test_floor :: proc(dt: ^Drudge_Test, x0, x1, floor_y: i32, rock: Cell) {
	drudge_fill_box(&dt.sb, x0, floor_y, x1, floor_y+8, rock)
}

@(test)
test_a_drudge_walks_until_a_wall_turns_it_around :: proc(t: ^testing.T) {
	dt, ok := drudge_test_setup(t)
	if !ok do return
	defer drudge_test_destroy(&dt)

	rock, found := find_material_index(dt.table, "Rock")
	if !testing.expect(t, found, "Rock must exist") do return

	floor_y := i32(100)
	drudge_test_floor(&dt, 0, 319, floor_y, Cell(rock))
	drudge_fill_box(&dt.sb, 120, floor_y-30, 130, floor_y-1, Cell(rock))

	terrain := Terrain{world = dt.world, sandbox = &dt.sb}
	player := Player{x = 300, y = f32(floor_y) - 60, facing = 1, on_ground = true}

	bag: Drudge_Bag
	bag.count = 1
	bag.drudges[0] = Drudge{x = 60, y = f32(floor_y), dir = 1, on_ground = true}

	pots: Pot_Bag
	turned := false
	for _ in 0 ..< 600 {
		drudge_step(&bag, &pots, terrain, player)
		if bag.drudges[0].dir < 0 {
			turned = true
			break
		}
	}
	testing.expect(t, turned, "a drudge walking into a wall must turn around")
	testing.expectf(
		t, bag.drudges[0].x < 120,
		"a drudge must not walk into the wall it turned at, got x=%v", bag.drudges[0].x,
	)
}

@(test)
test_a_drudge_turns_around_at_a_ledge_instead_of_walking_off_it :: proc(t: ^testing.T) {
	dt, ok := drudge_test_setup(t)
	if !ok do return
	defer drudge_test_destroy(&dt)

	rock, found := find_material_index(dt.table, "Rock")
	if !testing.expect(t, found, "Rock must exist") do return

	floor_y := i32(100)
	drudge_test_floor(&dt, 0, 120, floor_y, Cell(rock))

	terrain := Terrain{world = dt.world, sandbox = &dt.sb}
	player := Player{x = 300, y = f32(floor_y) - 60, facing = 1, on_ground = true}

	bag: Drudge_Bag
	bag.count = 1
	bag.drudges[0] = Drudge{x = 60, y = f32(floor_y), dir = 1, on_ground = true}

	pots: Pot_Bag
	for _ in 0 ..< 600 {
		drudge_step(&bag, &pots, terrain, player)
	}

	d := bag.drudges[0]
	testing.expectf(t, d.on_ground, "a drudge that turns at a ledge must never fall off it")
	testing.expectf(
		t, d.x < 120,
		"a drudge must turn before its own body clears the edge of the ground, got x=%v", d.x,
	)
}

@(test)
test_a_drudge_turns_around_after_walking_its_patrol_leg_even_on_open_ground :: proc(t: ^testing.T) {
	dt, ok := drudge_test_setup(t)
	if !ok do return
	defer drudge_test_destroy(&dt)

	rock, found := find_material_index(dt.table, "Rock")
	if !testing.expect(t, found, "Rock must exist") do return

	floor_y := i32(100)
	drudge_test_floor(&dt, 0, 319, floor_y, Cell(rock))

	terrain := Terrain{world = dt.world, sandbox = &dt.sb}
	player := Player{x = 300, y = f32(floor_y) - 60, facing = 1, on_ground = true}

	bag: Drudge_Bag
	bag.count = 1
	bag.drudges[0] = Drudge{x = 60, y = f32(floor_y), dir = 1, on_ground = true}

	pots: Pot_Bag
	turned := false
	for _ in 0 ..< 600 {
		drudge_step(&bag, &pots, terrain, player)
		if bag.drudges[0].dir < 0 {
			turned = true
			break
		}
	}
	testing.expect(t, turned, "a drudge on open, wall-less ground must still turn around, on the leash")
}

@(test)
test_a_drudge_does_not_chase_the_player_who_is_running_away :: proc(t: ^testing.T) {
	run :: proc(t: ^testing.T, near_player: bool) -> f32 {
		dt, ok := drudge_test_setup(t)
		if !ok do return 0
		defer drudge_test_destroy(&dt)

		rock, _ := find_material_index(dt.table, "Rock")
		floor_y := i32(100)
		drudge_test_floor(&dt, 0, 319, floor_y, Cell(rock))

		terrain := Terrain{world = dt.world, sandbox = &dt.sb}
		player := Player{x = near_player ? 90 : 3000, y = f32(floor_y) - 60, facing = -1, on_ground = true}

		bag: Drudge_Bag
		bag.count = 1
		bag.drudges[0] = Drudge{x = 60, y = f32(floor_y), dir = 1, on_ground = true}

		pots: Pot_Bag
		for _ in 0 ..< 90 {
			drudge_step(&bag, &pots, terrain, player)
			player.x += 10
		}
		return bag.drudges[0].x
	}

	with_player := run(t, true)
	without_player := run(t, false)
	testing.expectf(
		t, with_player == without_player,
		"a drudge's feet must not care whether the player is near or far, got %v against %v",
		with_player, without_player,
	)
}

@(test)
test_a_drudge_sees_the_player_in_the_open_and_not_through_a_wall :: proc(t: ^testing.T) {
	dt, ok := drudge_test_setup(t)
	if !ok do return
	defer drudge_test_destroy(&dt)

	rock, found := find_material_index(dt.table, "Rock")
	if !testing.expect(t, found, "Rock must exist") do return

	terrain := Terrain{world = dt.world, sandbox = &dt.sb}
	d := Drudge{x = 60, y = 40, dir = 1, on_ground = true}
	player := Player{x = 120, y = 40, facing = -1, on_ground = true}

	testing.expect(t, drudge_sees_player(terrain, d, player), "the player is in the open, ahead of him, and within range: he must see him")

	drudge_fill_box(&dt.sb, 90, 0, 92, 63, Cell(rock))
	testing.expect(t, !drudge_sees_player(terrain, d, player), "a wall between them must block his sight")

	behind := Player{x = 0, y = 40, facing = 1, on_ground = true}
	testing.expect(t, !drudge_sees_player(terrain, d, behind), "a player behind him must go unseen")
}

@(test)
test_a_drudge_throws_a_pot_toward_the_player_it_sees :: proc(t: ^testing.T) {
	d := Drudge{x = 60, y = 40, dir = 1, on_ground = true}
	player := Player{x = 160, y = 20, facing = -1, on_ground = true}

	bag: Pot_Bag
	testing.expect(t, drudge_throw(&bag, d, player), "he must be able to throw at a player he can aim at")
	if !testing.expect(t, bag.count == 1, "the throw must place exactly one pot") do return

	p := bag.pots[0]
	testing.expect(t, p.live, "the thrown pot must be live")
	testing.expectf(t, p.vx > 0, "the player is to his right, so the pot must fly right, got vx=%v", p.vx)
	testing.expectf(
		t, p.vy < 0,
		"the player is above him and the throw is a lob, so the pot must leave rising, got vy=%v", p.vy,
	)
}

@(test)
test_a_drudge_throws_no_faster_than_once_every_drudge_throw_interval :: proc(t: ^testing.T) {
	dt, ok := drudge_test_setup(t)
	if !ok do return
	defer drudge_test_destroy(&dt)

	rock, found := find_material_index(dt.table, "Rock")
	if !testing.expect(t, found, "Rock must exist") do return

	floor_y := i32(100)
	drudge_test_floor(&dt, 0, 319, floor_y, Cell(rock))

	terrain := Terrain{world = dt.world, sandbox = &dt.sb}
	player := Player{x = 90, y = f32(floor_y) - 30, facing = -1, on_ground = true}

	bag: Drudge_Bag
	bag.count = 1
	bag.drudges[0] = Drudge{x = 60, y = f32(floor_y), dir = 1, on_ground = true}

	pots: Pot_Bag
	throws_by_interval := 0
	for _ in 0 ..< int(DRUDGE_THROW_INTERVAL) {
		before := pots.count
		drudge_step(&bag, &pots, terrain, player)
		if pots.count > before do throws_by_interval += 1
	}
	testing.expectf(t, throws_by_interval == 1, "within one interval he must throw exactly once, got %d", throws_by_interval)

	for _ in 0 ..< int(DRUDGE_THROW_INTERVAL) {
		before := pots.count
		drudge_step(&bag, &pots, terrain, player)
		if pots.count > before do throws_by_interval += 1
	}
	testing.expectf(t, throws_by_interval == 2, "a second interval must allow exactly one more throw, got %d", throws_by_interval)
}

@(test)
test_a_drudge_resumes_patrol_after_losing_sight_of_the_player :: proc(t: ^testing.T) {
	dt, ok := drudge_test_setup(t)
	if !ok do return
	defer drudge_test_destroy(&dt)

	rock, found := find_material_index(dt.table, "Rock")
	if !testing.expect(t, found, "Rock must exist") do return

	floor_y := i32(100)
	drudge_test_floor(&dt, 0, 319, floor_y, Cell(rock))

	terrain := Terrain{world = dt.world, sandbox = &dt.sb}
	player := Player{x = 90, y = f32(floor_y) - 30, facing = -1, on_ground = true}

	bag: Drudge_Bag
	bag.count = 1
	bag.drudges[0] = Drudge{x = 60, y = f32(floor_y), dir = 1, on_ground = true}

	pots: Pot_Bag
	drudge_step(&bag, &pots, terrain, player)
	if !testing.expect(t, bag.drudges[0].sight > 0, "this test means nothing unless he first sees the player") do return
	testing.expect(t, drudge_facing(bag.drudges[0], player) == 1, "seeing him to the right, he must face right")

	player.x = 3000
	for _ in 0 ..< int(DRUDGE_ALERT_HOLD)+2 {
		drudge_step(&bag, &pots, terrain, player)
	}

	testing.expectf(t, bag.drudges[0].sight == 0, "losing sight for longer than the hold must forget the player")
	testing.expect(
		t, drudge_facing(bag.drudges[0], player) == bag.drudges[0].dir,
		"once he forgets the player, he must face his own patrol direction again",
	)
}

@(test)
test_the_shipped_world_places_a_drudge_the_player_can_reach :: proc(t: ^testing.T) {
	s: Sim
	if !testing.expect(t, sim_load(&s) == .None, "the world must load") do return
	defer sim_unload(&s)

	if !testing.expect(t, s.drudges.count == 1, "the shipped world must place exactly one drudge") do return

	d := s.drudges.drudges[0]
	terrain := Terrain{world = s.world}
	testing.expect(t, drudge_body_clear(terrain, d.x, d.y), "the drudge must not spawn embedded in the world")
	testing.expect(t, drudge_on_ground(terrain, d.x, d.y), "the drudge must spawn standing on solid ground")

	dist := d.x - s.player.x
	testing.expectf(
		t, dist > 0,
		"he is placed right of the wizard's own spawn, and he is %v cells from it", dist,
	)
	testing.expectf(
		t, dist < 4*DRUDGE_SPAWN_X_OFFSET,
		"he must land somewhere near the offset the plan names, not far down a shaft, got %v cells", dist,
	)
}
