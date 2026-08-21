package game

import "core:testing"

POND_MAX :: 4

POND_RX :: 26
POND_RY :: 15
POND_SHELL :: 5
POND_LIP :: 8
POND_AWAY :: 96
POND_DROP :: 2

Pond :: struct {
	x, y:   i32,
	rx, ry: i32,
	water:  Cell,
	bank:   Cell,
}

pond_place :: proc(world: World, spawn_x, spawn_y: i32) -> (p: Pond, ok: bool) {
	water, water_found := find_material_index(world.materials, "Water")
	bank, bank_found := find_material_index(world.materials, "Rock")
	if !water_found || !bank_found do return {}, false

	return Pond {
			x = spawn_x - POND_AWAY,
			y = spawn_y + POND_DROP,
			rx = POND_RX,
			ry = POND_RY,
			water = Cell(water),
			bank = Cell(bank),
		},
		true
}

pond_span :: #force_inline proc(p: Pond) -> i32 {
	return p.rx + POND_SHELL
}

@(private = "file")
pond_under :: #force_inline proc(p: Pond, dx, dy, grow: i32) -> bool {
	rx := p.rx + grow
	ry := p.ry + grow
	if dx < -rx || dx > rx || dy > ry do return false
	return dx * dx * ry * ry + dy * dy * rx * rx <= rx * rx * ry * ry
}

@(private = "file")
pond_over :: #force_inline proc(p: Pond, dx, dy: i32) -> bool {
	if dx < -p.rx || dx > p.rx || dy < -POND_LIP do return false
	return dx * dx * POND_LIP * POND_LIP + dy * dy * p.rx * p.rx <= p.rx * p.rx * POND_LIP * POND_LIP
}

pond_cell :: proc(p: Pond, wx, wy: i32, under: Cell) -> Cell {
	dx := wx - p.x
	dy := wy - p.y

	if dy < 0 do return pond_over(p, dx, dy) ? MATERIAL_AIR : under
	if pond_under(p, dx, dy, 0) do return p.water
	if pond_under(p, dx, dy, POND_SHELL) do return p.bank
	return under
}

pond_carves :: proc(p: Pond, wx, wy: i32) -> bool {
	dx := wx - p.x
	dy := wy - p.y

	if dy < 0 do return pond_over(p, dx, dy)
	return pond_under(p, dx, dy, POND_SHELL)
}

world_pond_cell :: proc(world: World, wx, wy: i32, under: Cell) -> Cell {
	c := under
	for i in 0 ..< int(world.pond_count) {
		c = pond_cell(world.ponds[i], wx, wy, c)
	}
	return c
}

world_pond_carves :: proc(world: World, wx, wy: i32) -> bool {
	for i in 0 ..< int(world.pond_count) {
		if pond_carves(world.ponds[i], wx, wy) do return true
	}
	return false
}

world_add_pond :: proc(world: ^World, p: Pond) -> bool {
	if world.pond_count >= POND_MAX do return false
	world.ponds[world.pond_count] = p
	world.pond_count += 1
	return true
}

@(private = "file")
pond_test_world :: proc(t: ^testing.T, s: ^Sim) -> (p: Pond, ok: bool) {
	if !testing.expect(t, sim_load(s) == .None, "the world must load") do return {}, false
	if !testing.expect(t, s.world.pond_count > 0, "the shipped world must dig a pond") {
		sim_unload(s)
		return {}, false
	}
	return s.world.ponds[0], true
}

@(test)
test_the_pond_holds_its_water_in_a_bowl_that_cannot_leak :: proc(t: ^testing.T) {
	s: Sim
	p, ok := pond_test_world(t, &s)
	if !ok do return
	defer sim_unload(&s)

	span := pond_span(p)
	leaks := 0

	for wy in p.y ..= p.y + p.ry + POND_SHELL {
		for wx in p.x - span ..= p.x + span {
			if world_cell_at(s.world, wx, wy) != p.water do continue

			for step in ([4][2]i32{{1, 0}, {-1, 0}, {0, 1}, {0, -1}}) {
				nx := wx + step[0]
				ny := wy + step[1]
				if ny < p.y do continue

				n := world_cell_at(s.world, nx, ny)
				if n == p.water || n == p.bank do continue
				leaks += 1
			}
		}
	}

	testing.expectf(
		t,
		leaks == 0,
		"water must be walled in by the bank on every side but the top, and %d cells are not",
		leaks,
	)
}

@(test)
test_the_pond_is_open_to_the_sky_above_its_water :: proc(t: ^testing.T) {
	s: Sim
	p, ok := pond_test_world(t, &s)
	if !ok do return
	defer sim_unload(&s)

	for wy in p.y - POND_LIP ..< p.y {
		testing.expectf(
			t,
			world_cell_at(s.world, p.x, wy) == MATERIAL_AIR,
			"the mouth of the pond must be open air at %d,%d, and it holds %s",
			p.x,
			wy,
			s.world.materials.names[world_cell_at(s.world, p.x, wy)],
		)
	}

	testing.expect(
		t,
		world_cell_at(s.world, p.x, p.y) == p.water,
		"and the row under the mouth must be the water",
	)
}

@(test)
test_the_pond_leaves_the_spawn_where_it_was :: proc(t: ^testing.T) {
	s: Sim
	_, ok := pond_test_world(t, &s)
	if !ok do return
	defer sim_unload(&s)

	bare := s.world
	bare.pond_count = 0

	want_x, want_y, found := world_find_spawn(bare)
	if !testing.expect(t, found, "the shipped map must offer a spawn point") do return

	got_x, got_y, still := world_find_spawn(s.world)
	testing.expect(t, still, "digging a pond must not take the spawn point away")
	testing.expectf(
		t,
		got_x == want_x && got_y == want_y,
		"a pond is not a way into the caves: the spawn moved to %d,%d from %d,%d",
		got_x,
		got_y,
		want_x,
		want_y,
	)

	testing.expectf(
		t,
		!world_pond_carves(s.world, i32(s.player.x), i32(s.player.y)),
		"and it must not be dug where he stands, at %v,%v",
		s.player.x,
		s.player.y,
	)
}

@(test)
test_the_pond_is_close_enough_to_the_spawn_to_walk_to :: proc(t: ^testing.T) {
	s: Sim
	pond, ok := pond_test_world(t, &s)
	if !ok do return
	defer sim_unload(&s)

	away := abs(i32(s.player.x) - pond.x) - pond_span(pond)
	testing.expectf(
		t,
		away > PLAYER_BODY_W,
		"the pond must not open under his feet, and its bank is %d cells from him",
		away,
	)
	testing.expectf(
		t,
		away < 4 * SANDBOX_PLAY_SIZE / 16,
		"the pond must be a short walk from the spawn, and it is %d cells away",
		away,
	)
	testing.expectf(
		t,
		abs(i32(s.player.y) - pond.y) < SANDBOX_PLAY_SIZE / 2,
		"and it must lie in the square the sandbox opens on, %d cells below him",
		pond.y - i32(s.player.y),
	)
}

@(test)
test_the_pond_reaches_the_world_the_same_way_down_both_paths :: proc(t: ^testing.T) {
	s: Sim
	p, ok := pond_test_world(t, &s)
	if !ok do return
	defer sim_unload(&s)

	span := pond_span(p)
	views := []World_View {
		{x = p.x - span - 4, y = p.y - POND_LIP - 4, w = 2 * span + 8, h = p.ry + POND_SHELL + POND_LIP + 8, step = 1},
		{x = p.x - span - 3, y = p.y - POND_LIP - 1, w = 90, h = 40, step = 3},
		{x = p.x - 200, y = p.y - 100, w = 128, h = 96, step = 5},
	}

	for view in views {
		cells := make([]Cell, int(view.w) * int(view.h))
		defer delete(cells)
		generate(s.world, view, cells)

		water_seen := 0
		for ty in 0 ..< view.h {
			for tx in 0 ..< view.w {
				wx := view.x + tx * view.step
				wy := view.y + ty * view.step
				got := cells[int(ty) * int(view.w) + int(tx)]
				if got == p.water do water_seen += 1

				testing.expectf(
					t,
					got == world_cell_at(s.world, wx, wy),
					"the run fill says %d at %d,%d and the plain path says %d",
					got,
					wx,
					wy,
					world_cell_at(s.world, wx, wy),
				)
			}
		}
		testing.expectf(t, water_seen > 0, "the view %v must hold some of the pond", view)
	}
}

@(test)
test_the_pond_is_the_only_thing_the_overlay_touches :: proc(t: ^testing.T) {
	s: Sim
	p, ok := pond_test_world(t, &s)
	if !ok do return
	defer sim_unload(&s)

	bare := s.world
	bare.pond_count = 0

	span := pond_span(p)
	for wy in p.y - POND_LIP - 8 ..= p.y + p.ry + POND_SHELL + 8 {
		for wx in p.x - span - 8 ..= p.x + span + 8 {
			if world_cell_at(s.world, wx, wy) == world_cell_at(bare, wx, wy) do continue
			testing.expectf(
				t,
				world_pond_carves(s.world, wx, wy),
				"the cell at %d,%d changed and no pond claims it",
				wx,
				wy,
			)
		}
	}
}
