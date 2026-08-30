package game

import "core:testing"

// What water has to do to read as water.
//
// The sandbox is a falling-sand grid, so a liquid is a cell that swaps
// with a lighter one. That alone makes a heap, not a pool: before
// sandbox_flow, a column of water on a flat floor settled into a 45
// degree wedge within 50 ticks and had not moved at tick 12000. The
// tests here are the measurements that say it is a fluid now, and each
// one names the number the design note quotes.
//
// See docs/physics.md, "The reach is the flatness", for the rule they
// hold, and sandbox_flow for the code.

@(private = "file")
fluid_sandbox :: proc(t: ^testing.T, width, height: i32) -> (Sandbox, Material_Table) {
	table, load_ok := load_materials("data/materials.txt")
	testing.expect(t, load_ok, "materials must load")
	sb, make_ok := sandbox_make(width, height, 7)
	testing.expect(t, make_ok, "the sandbox must be created")
	return sb, table
}

@(private = "file")
fluid_fill :: proc(sb: ^Sandbox, table: Material_Table, x0, y0, x1, y1: i32, name: string) {
	c, found := find_material_index(table, name)
	if !found do return
	for y in y0 ..= y1 {
		for x in x0 ..= x1 {
			i := sandbox_index(sb, x, y)
			sb.cells[i] = Cell(c)
			sb.lifetime[i] = material_start_life(table, Cell(c))
		}
	}
	sandbox_mark_all(sb)
}

// The topmost cell of `name` in each column, or -1 where there is none.
@(private = "file")
fluid_surface :: proc(sb: ^Sandbox, table: Material_Table, name: string) -> []i32 {
	c, _ := find_material_index(table, name)
	out := make([]i32, sb.width)
	for x in i32(0) ..< sb.width {
		out[x] = -1
		for y in i32(0) ..< sb.height {
			if sandbox_cell(sb, x, y) == Cell(c) {
				out[x] = y
				break
			}
		}
	}
	return out
}

@(private = "file")
fluid_count :: proc(sb: ^Sandbox, table: Material_Table, name: string) -> (n: int) {
	c, _ := find_material_index(table, name)
	for v in sb.cells do if v == Cell(c) do n += 1
	return n
}

// The surface of a pool falls about one cell every `spread` cells, so
// water (64) laid down as a tall column at one end of a long floor
// spreads the length of it and comes to rest nearly level. The old rule
// stopped this water at x=21 of 200 with 26 cells of slope in it.
@(test)
test_a_pool_of_water_levels_the_length_of_its_floor :: proc(t: ^testing.T) {
	sb, table := fluid_sandbox(t, 200, 40)
	defer sandbox_destroy(&sb)
	defer destroy_material_table(table)

	fluid_fill(&sb, table, 0, 39, 199, 39, "Rock")
	fluid_fill(&sb, table, 1, 9, 20, 38, "Water")
	poured := fluid_count(&sb, table, "Water")

	for _ in 0 ..< 2000 do sandbox_step(&sb, table)

	s := fluid_surface(&sb, table, "Water")
	defer delete(s)

	reach := i32(0)
	high, low := i32(1 << 20), i32(-1)
	for x in i32(0) ..< sb.width {
		if s[x] < 0 do continue
		reach = x
		high = min(high, s[x])
		low = max(low, s[x])
	}

	testing.expectf(
		t, reach >= 180,
		"water must spread the length of the floor, and it reached x=%d of 200", reach,
	)
	testing.expectf(
		t, low - high <= 6,
		"and lie nearly level, and its surface falls %d cells from row %d to row %d",
		low - high, high, low,
	)
	testing.expectf(
		t, fluid_count(&sb, table, "Water") == poured,
		"and no cell of it may be lost: %d poured, %d left",
		poured, fluid_count(&sb, table, "Water"),
	)
}

// A pool drains through an opening under its own surface. The old rule
// let eight cells through and then held: a liquid could only step aside
// at its own surface, so a submerged hole was a hole nothing could reach.
@(test)
test_water_drains_through_a_submerged_opening :: proc(t: ^testing.T) {
	sb, table := fluid_sandbox(t, 60, 40)
	defer sandbox_destroy(&sb)
	defer destroy_material_table(table)

	fluid_fill(&sb, table, 0, 0, 59, 39, "Rock")
	fluid_fill(&sb, table, 1, 1, 58, 38, "Air")
	fluid_fill(&sb, table, 29, 1, 31, 38, "Rock")   // a wall across the middle
	fluid_fill(&sb, table, 29, 34, 31, 38, "Air")   // with a hole at the foot of it
	fluid_fill(&sb, table, 1, 9, 28, 38, "Water")   // water on one side only

	for _ in 0 ..< 400 do sandbox_step(&sb, table)

	crossed := 0
	water, _ := find_material_index(table, "Water")
	for y in i32(0) ..< sb.height {
		for x in i32(32) ..< 59 {
			if sandbox_cell(&sb, x, y) == Cell(water) do crossed += 1
		}
	}
	testing.expectf(
		t, crossed > 60,
		"water must pass a submerged opening, and only %d cells of it crossed",
		crossed,
	)
}

// A gas gathers under the roof it rises to and runs along it, rather
// than piling in the corner it came up in. The old rule left 50 cells of
// gas in a heap eleven wide against one wall of a room fifty-eight wide.
@(test)
test_a_gas_runs_along_the_roof_it_gathers_under :: proc(t: ^testing.T) {
	sb, table := fluid_sandbox(t, 60, 26)
	defer sandbox_destroy(&sb)
	defer destroy_material_table(table)

	fluid_fill(&sb, table, 0, 0, 59, 25, "Rock")
	fluid_fill(&sb, table, 1, 1, 58, 24, "Air")
	fluid_fill(&sb, table, 2, 20, 11, 24, "Flammable_Gas")

	for _ in 0 ..< 600 do sandbox_step(&sb, table)

	gas, _ := find_material_index(table, "Flammable_Gas")
	west, east, deepest := i32(1 << 20), i32(-1), i32(-1)
	for y in i32(0) ..< sb.height {
		for x in i32(0) ..< sb.width {
			if sandbox_cell(&sb, x, y) != Cell(gas) do continue
			west = min(west, x)
			east = max(east, x)
			deepest = max(deepest, y)
		}
	}
	testing.expectf(
		t, east - west >= 30,
		"the gas must run along the roof, and it lies in %d cells of it", east - west + 1,
	)
	testing.expectf(
		t, deepest <= 4,
		"and lie under the roof rather than filling the room, and it reaches row %d",
		deepest,
	)
}

// A dam with a notch in it empties the pond behind into the basin below,
// and the basin holds it level. This is the shape the village pond is
// built to: see tools/seed_homelands.py, "the millpond".
@(test)
test_a_dammed_pond_empties_into_a_basin_and_the_basin_lies_level :: proc(t: ^testing.T) {
	sb, table := fluid_sandbox(t, 100, 44)
	defer sandbox_destroy(&sb)
	defer destroy_material_table(table)

	fluid_fill(&sb, table, 0, 0, 99, 43, "Rock")
	fluid_fill(&sb, table, 2, 4, 40, 20, "Air")     // the pond bowl
	fluid_fill(&sb, table, 44, 4, 97, 40, "Air")    // the basin under the dam
	fluid_fill(&sb, table, 41, 10, 43, 40, "Air")   // the notch, and the face below it
	fluid_fill(&sb, table, 2, 5, 40, 20, "Water")   // the pond, full to the brim
	poured := fluid_count(&sb, table, "Water")

	for _ in 0 ..< 900 do sandbox_step(&sb, table)

	s := fluid_surface(&sb, table, "Water")
	defer delete(s)

	high, low, wide := i32(1 << 20), i32(-1), 0
	for x in i32(45) ..< 97 {
		if s[x] < 0 do continue
		wide += 1
		high = min(high, s[x])
		low = max(low, s[x])
	}
	testing.expectf(
		t, wide >= 50,
		"the water must reach the far end of the basin, and it stands in %d of its 52 columns",
		wide,
	)
	testing.expectf(
		t, low - high <= 2,
		"and lie level there, and its surface falls %d cells", low - high,
	)
	testing.expectf(
		t, fluid_count(&sb, table, "Water") == poured,
		"and none of the pond may be lost on the way: %d poured, %d left",
		poured, fluid_count(&sb, table, "Water"),
	)
}

// The reach is what a fluid pays for. A thick liquid names a small one
// and keeps a slope; the flatness of a pool is the number in its row.
@(test)
test_a_thick_liquid_keeps_the_slope_a_runny_one_loses :: proc(t: ^testing.T) {
	slope_of :: proc(t: ^testing.T, name: string) -> i32 {
		sb, table := fluid_sandbox(t, 120, 40)
		defer sandbox_destroy(&sb)
		defer destroy_material_table(table)

		fluid_fill(&sb, table, 0, 39, 119, 39, "Rock")
		fluid_fill(&sb, table, 1, 19, 20, 38, name)
		for _ in 0 ..< 2000 do sandbox_step(&sb, table)

		s := fluid_surface(&sb, table, name)
		defer delete(s)
		high, low := i32(1 << 20), i32(-1)
		for x in i32(0) ..< sb.width {
			if s[x] < 0 do continue
			high = min(high, s[x])
			low = max(low, s[x])
		}
		return low - high
	}

	water := slope_of(t, "Water")
	lava := slope_of(t, "Lava")
	testing.expectf(
		t, water < lava,
		"lava must hold a slope water loses: water falls %d cells, lava %d",
		water, lava,
	)
}

// A settled pool costs nothing. The whole point of the dirty chunks is
// that still water is free, and a rule that reads along a row must not
// spend that: a packed pool is stopped by its own kind one cell away, so
// it sleeps. Only a fluid that sees open cells the whole length of its
// reach keeps watch, and a pond in a bowl has none.
@(test)
test_a_settled_pond_goes_back_to_sleep :: proc(t: ^testing.T) {
	sb, table := fluid_sandbox(t, 200, 60)
	defer sandbox_destroy(&sb)
	defer destroy_material_table(table)

	fluid_fill(&sb, table, 0, 0, 199, 59, "Rock")
	fluid_fill(&sb, table, 11, 20, 189, 54, "Air")
	fluid_fill(&sb, table, 11, 40, 189, 54, "Water")

	for _ in 0 ..< 400 do sandbox_step(&sb, table)

	awake := 0
	for r in sb.dirty do if r.min_x <= r.max_x do awake += 1
	testing.expectf(
		t, awake == 0,
		"a settled pond must wake no chunk, and %d of %d are awake",
		awake, len(sb.dirty),
	)

	before := make([]Cell, len(sb.cells))
	defer delete(before)
	copy(before, sb.cells)
	for _ in 0 ..< 200 do sandbox_step(&sb, table)

	moved := 0
	for c, i in sb.cells do if c != before[i] do moved += 1
	testing.expectf(t, moved == 0, "and not one of its cells may move, and %d did", moved)
}
