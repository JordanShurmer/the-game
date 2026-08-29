package game

import testing "check"

// The pond is a tile.
//
// It used to be an overlay dug beside the spawn, because the spawn was
// beside a cave mouth and a pond was the one landmark the surface had.
// The surface is a village now and the village is daylit, and a pond
// of fireflies belongs in the dark, so the pond moved underground --
// into the Grotto, one authored tile of the Coalmine's wang set,
// painted by tools/seed_tiles.py: a dome of cave over a rock bowl of
// still water, sealed on every side but the east.
//
// Nothing in the game knows that. The water is cells of the tile, read
// through the same path as every other cell; the fireflies are cells
// of Firefly_Light painted over the water, lifted out by the loader as
// marks (see Tile_Mark) and gathered into the swarm by firefly_gather.
// The lattice decides where the Grotto's instances lie, so every world
// has its own ponds in its own places, and another tile of another
// biome could paint a pond of its own without touching a line of code.
//
// What is here is the tests that hold the shipped Grotto to being a
// pond: water that cannot leak, fireflies that hang over water, and at
// least one of it within digging reach of the village.
//
// And the millpond, which is the other pond and the opposite of this
// one. The Grotto is still water in a sealed bowl; the millpond is a
// pond over a dam with a spillway cut through it, drawn full so that
// the first tick of the world sends it through the dam and down into a
// dry pool. It is authored in tools/seed_homelands.py rather than in a
// tile, it is on the surface where the day lights it, and it is fifty
// cells west of where he lands. See docs/homelands.md, "The millpond".

// The tile the shipped world's firefly marks are painted in. The marks
// are the only thing that names it: the tile that carries fireflies is
// the pond, whichever tile that is.
@(private = "file")
grotto_of :: proc(world: ^World, t: ^testing.T) -> (tile: Tile_Id, ok: bool) {
	firefly := world.materials.firefly
	for m in world.tiles.marks {
		if m.material == firefly do return m.tile, true
	}
	testing.expect(t, false, "some tile of the shipped world must carry firefly marks")
	return TILE_NONE, false
}

@(test)
test_the_grotto_holds_its_water_in_a_bowl_that_cannot_leak :: proc(t: ^testing.T) {
	s: Sim
	if !testing.expect(t, sim_load(&s) == .None, "the world must load") do return
	defer sim_unload(&s)

	tile, ok := grotto_of(&s.world, t)
	if !ok do return

	water, _ := find_material_index(s.world.materials, "Water")
	air, _ := find_material_index(s.world.materials, "Air")

	cells := 0
	leaks := 0
	for y in i32(1) ..< TILE_SIZE - 1 {
		for x in i32(1) ..< TILE_SIZE - 1 {
			if tile_at(s.world.tiles, tile, x, y) != Cell(water) do continue
			cells += 1

			for step in ([4][2]i32{{1, 0}, {-1, 0}, {0, 1}, {0, -1}}) {
				n := tile_at(s.world.tiles, tile, x + step[0], y + step[1])
				if n == Cell(air) && step[1] >= 0 do leaks += 1
			}
		}
	}

	testing.expect(t, cells > 1000, "the Grotto must hold a pond, not a puddle")
	testing.expectf(
		t,
		leaks == 0,
		"water may meet air only above itself, and %d cells of it do not",
		leaks,
	)
}

@(test)
test_the_fireflies_hang_over_water_within_reach_of_the_village :: proc(t: ^testing.T) {
	s: Sim
	if !testing.expect(t, sim_load(&s) == .None, "the world must load") do return
	defer sim_unload(&s)

	if !testing.expect(t, s.flies.count > 0, "the shipped world must gather a swarm") do return

	water, _ := find_material_index(s.world.materials, "Water")

	// Every fly hangs in open air with the pond's water below it.
	for i in 0 ..< int(s.flies.count) {
		f := s.flies.flies[i]
		x := i32(f.home_x)
		y := i32(f.home_y)

		testing.expectf(
			t,
			world_cell_at(s.world, x, y) == MATERIAL_AIR,
			"a firefly hangs in the air, and one was painted into %s at %d,%d",
			s.world.materials.names[world_cell_at(s.world, x, y)], x, y,
		)

		wet := false
		for dy in i32(1) ..= 48 {
			c := world_cell_at(s.world, x, y + dy)
			if c == Cell(water) {
				wet = true
				break
			}
			if c != MATERIAL_AIR do break
		}
		testing.expectf(t, wet, "and over water, and the one at %d,%d is not", x, y)
	}

	// And the nearest of them is a short dig from where he starts: the
	// pond is the reward for going down, not a rumour three squares off.
	nearest := max(f32)
	for i in 0 ..< int(s.flies.count) {
		f := s.flies.flies[i]
		dx := abs(f.home_x - s.player.x)
		dy := abs(f.home_y - s.player.y)
		nearest = min(nearest, max(dx, dy))
	}
	testing.expectf(
		t,
		nearest < 3 * TILE_SIZE,
		"the nearest firefly must be within three tiles of the spawn, and it is %.0f cells away",
		nearest,
	)
}


// The millpond.
//
// It is drawn into one homelands picture, and the world's seed decides
// which region draws that picture. On the shipped seed it is the region
// he starts in. That is the whole point of it -- a fluid simulation
// nobody walks past is a fluid simulation nobody sees -- so it is held
// here: change the seed and this test says the mill has moved.
@(test)
test_the_wizard_starts_within_sight_of_the_millpond :: proc(t: ^testing.T) {
	s: Sim
	if !testing.expect(t, sim_load(&s) == .None, "the world must load") do return
	defer sim_unload(&s)

	water, _ := find_material_index(s.world.materials, "Water")

	// The window opens 320 cells wide on him. Anything he can see from
	// where he lands is within half of that either side.
	reach := i32(160)
	px, py := i32(s.player.x), i32(s.player.y)

	cells, west, east := 0, i32(1 << 20), i32(-1 << 20)
	for y in py - reach ..= py + reach {
		for x in px - reach ..= px + reach {
			if world_cell_at(s.world, x, y) != Cell(water) do continue
			cells += 1
			west = min(west, x)
			east = max(east, x)
		}
	}

	testing.expectf(
		t, cells > 400,
		"the wizard must land within sight of the millpond, and there are %d cells of water in the view",
		cells,
	)
	testing.expectf(
		t, east - west > 40,
		"and it must be a pond and not a puddle: the water spans %d cells",
		east - west + 1,
	)
}

// And what it does. The pond is drawn full, over the head of the
// spillway; the pool under the dam is drawn dry. Left to run, the pond
// goes through the dam, falls, fills the pool, and the two come to rest
// -- each of them level, the pond standing over the pool, and not one
// cell of water lost on the way.
//
// This is the fluid simulation measured where the player meets it. The
// rules it holds are in docs/physics.md, "The reach is the flatness",
// and the small ones are covered by src/fluid_test.odin; this is the
// whole thing, in the shipped world.
@(test)
test_the_millpond_runs_through_the_dam_and_settles_over_the_pool :: proc(t: ^testing.T) {
	s: Sim
	if !testing.expect(t, sim_load(&s) == .None, "the world must load") do return
	defer sim_unload(&s)

	water, _ := find_material_index(s.world.materials, "Water")

	// A sandbox over the mill, wide enough to hold the whole of it and
	// the ground either side.
	w, h := i32(160), i32(72)
	x0 := i32(s.player.x) - 152
	y0 := i32(s.player.y) - 20
	if !testing.expect(t, sim_open_sandbox(&s, w, h, x0, y0, 7, 0) == .None, "a sandbox over the mill") do return

	surface :: proc(sb: ^Sandbox, water: int) -> (top: []i32, cells: int) {
		top = make([]i32, sb.width)
		for x in i32(0) ..< sb.width {
			top[x] = -1
			for y in i32(0) ..< sb.height {
				if sandbox_cell(sb, x, y) != Cell(water) do continue
				if top[x] < 0 do top[x] = y
				cells += 1
			}
		}
		return top, cells
	}

	drawn, poured := surface(&s.sandbox, water)
	delete(drawn)
	testing.expectf(t, poured > 700, "the pond must be drawn full, and it holds %d cells", poured)

	for _ in 0 ..< 2500 do sandbox_step(&s.sandbox, s.world.materials)

	top, left := surface(&s.sandbox, water)
	defer delete(top)
	testing.expectf(
		t, left == poured,
		"not one cell of the pond may be lost on the way: %d poured, %d left", poured, left,
	)

	// Two bodies of water, with the dam between them.
	runs: [4]struct{x0, x1, high, low: i32}
	count := 0
	x := i32(0)
	for x < s.sandbox.width {
		if top[x] < 0 {
			x += 1
			continue
		}
		start := x
		high, low := i32(1 << 20), i32(-1)
		for x < s.sandbox.width && top[x] >= 0 {
			high = min(high, top[x])
			low = max(low, top[x])
			x += 1
		}
		if count < len(runs) do runs[count] = {start, x - 1, high, low}
		count += 1
	}
	settled := testing.expectf(
		t, count == 2,
		"the mill must come to rest as a pond and a pool with the dam between them, and it left %d bodies of water",
		count,
	)
	if !settled do return

	pond, pool := runs[0], runs[1]
	testing.expectf(
		t, pond.low - pond.high <= 2,
		"the pond must lie level, and its surface falls %d cells over %d columns",
		pond.low - pond.high, pond.x1 - pond.x0 + 1,
	)
	testing.expectf(
		t, pool.low - pool.high <= 2,
		"so must the pool, and its surface falls %d cells over %d columns",
		pool.low - pool.high, pool.x1 - pool.x0 + 1,
	)
	testing.expectf(
		t, pool.x1 - pool.x0 >= 30,
		"the pool must fill the width of its own floor, and the water in it is %d cells across",
		pool.x1 - pool.x0 + 1,
	)
	testing.expectf(
		t, pool.high > pond.low + 2,
		"and stand well under the pond, which is what the dam is for: pond at row %d, pool at row %d",
		pond.low, pool.high,
	)
}
