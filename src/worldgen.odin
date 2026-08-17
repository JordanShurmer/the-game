package game

import "core:os"
import "core:slice"
import "core:testing"

/*
World generation.

The world is unbounded. Any rectangle of it generates alone, in any
order, from the biome map only. The generator never reads a neighbour
region and holds no state between calls, so the result is the same
whatever the player has already visited.

Phase 2 has two generators. Uniform makes a region one flat material.
Tile repeats one authored tile through the region. The shape of this
proc did not change when Tile arrived, and it does not change when the
herringbone lattice arrives: only the body of the per-region fill does.
*/

// A world cell holds a material id. One byte per cell keeps a screen
// of world inside a small buffer.
Cell :: u8

/*
Everything generation reads. The app owns one of these and hands it
to the generator, so the editor and the game share one path.
*/
World :: struct {
	materials: Material_Table,
	biomes:    Biome_Table,
	biome_map: Biome_Map,
	tiles:     Tile_Set,
	seed:      u64, // reserved for wang tile placement in Phase 3
}

/*
A request for a rectangle of world.

`step` is how many world cells one output texel covers. It is 1 for
the native view. Larger values sample a wider area into the same
buffer, which lets the camera pull back and show whole regions. The
uniform generator is exact at any step, because a sample never
misses detail that is not there.

A tile biome is not exact above step 1. The view point samples the
tile and skips the cells between, so fine paint aliases when the
camera pulls back. That is a property of the view, not of the world:
the cells themselves are the same either way, and step 1 shows every
one of them. Averaging a wider area would read as a blur and hide the
paint, so the view stays honest and samples.
*/
World_View :: struct {
	x:    i32, // world cell at the top-left texel
	y:    i32,
	w:    i32, // output size in texels
	h:    i32,
	step: i32, // world cells per texel; 1 or more
}

// Floored division. The world has negative coordinates, and truncating
// division would fold the region either side of zero into one.
floor_div :: proc(a, b: i32) -> i32 {
	q := a / b
	if (a % b != 0) && ((a < 0) != (b < 0)) do q -= 1
	return q
}

// Ceiled division for a positive divisor.
@(private = "file")
ceil_div :: proc(a, b: i32) -> i32 {
	q := a / b
	if (a % b != 0) && (a > 0) do q += 1
	return q
}

// The biome that owns a world cell. Cells outside the map, and cells
// in map pixels nobody painted, belong to the off-map biome.
world_biome_at :: proc(world: World, wx, wy: i32) -> Biome_Id {
	cpp := world.biomes.cells_per_pixel
	map_x := floor_div(wx, cpp) + world.biomes.origin_pixel_x
	map_y := floor_div(wy, cpp) + world.biomes.origin_pixel_y

	id := biome_map_at(world.biome_map, map_x, map_y)
	if id == BIOME_EMPTY do id = world.biomes.off_map_biome
	return id
}

/*
The material one world cell holds.

This is the whole of generation for a single cell, and every path
goes through it: the fast run fill below, the HUD readout, and the
tests. One place decides what a cell is, so the editor and the game
cannot drift apart.
*/
world_cell_at :: proc(world: World, wx, wy: i32) -> Cell {
	b := world.biomes.biomes[world_biome_at(world, wx, wy)]
	if b.tile == TILE_NONE do return Cell(b.fill_0)
	return tile_sample(world.tiles, b.tile, wx, wy)
}

/*
Generate a view into a caller-owned buffer. There is no chunk store:
a chunk is only how much the caller asks for.

The inner loop works one region at a time, because the biome lookup
costs the same for one cell as for a thousand. What it does with the
run depends on the generator: a uniform region is one store per run,
and a tile region reads the tile per cell. Both write the same run of
texels, so the loop that finds the run is shared.
*/
generate :: proc(world: World, view: World_View, out: []Cell) {
	assert(view.step >= 1, "step must be 1 or more")
	assert(len(out) >= int(view.w) * int(view.h), "output buffer is too small")

	cpp := world.biomes.cells_per_pixel

	for ty in 0 ..< view.h {
		wy := view.y + ty * view.step
		map_y := floor_div(wy, cpp) + world.biomes.origin_pixel_y
		row := out[int(ty) * int(view.w):][:view.w]

		tx: i32 = 0
		for tx < view.w {
			wx := view.x + tx * view.step
			region_x := floor_div(wx, cpp)
			map_x := region_x + world.biomes.origin_pixel_x

			id := biome_map_at(world.biome_map, map_x, map_y)
			if id == BIOME_EMPTY do id = world.biomes.off_map_biome
			b := world.biomes.biomes[id]

			// The run reaches to the next region edge, because the biome
			// cannot change before then.
			next_region_start := (region_x + 1) * cpp
			tx_end := ceil_div(next_region_start - view.x, view.step)
			tx_end = clamp(tx_end, tx + 1, view.w)

			if b.tile == TILE_NONE {
				slice.fill(row[tx:tx_end], Cell(b.fill_0))
			} else {
				// One row of the tile, wrapped. The y wrap is the same for
				// every texel in the run, so it is lifted out of the loop.
				tile := tile_cells(world.tiles, b.tile)
				tile_row := tile[int(wy & TILE_MASK) * TILE_SIZE:][:TILE_SIZE]
				for t in tx ..< tx_end {
					row[t] = tile_row[(view.x + t * view.step) & TILE_MASK]
				}
			}
			tx = tx_end
		}
	}
}

// ------------------------------------------------------------
// Tests
// ------------------------------------------------------------

/*
The plain version of generate: one texel at a time, no runs, straight
through world_cell_at. It is the oracle the fast path is checked
against. If the two ever differ, the run arithmetic or the lifted
tile row is wrong.
*/
@(private = "file")
generate_naive :: proc(world: World, view: World_View, out: []Cell) {
	for ty in 0 ..< view.h {
		for tx in 0 ..< view.w {
			wx := view.x + tx * view.step
			wy := view.y + ty * view.step
			out[int(ty) * int(view.w) + int(tx)] = world_cell_at(world, wx, wy)
		}
	}
}

@(private = "file")
make_test_world :: proc(t: ^testing.T) -> (world: World, ok: bool) {
	materials, mat_ok := load_materials("data/materials.txt")
	if !testing.expect(t, mat_ok, "materials must load") do return {}, false

	biomes, err, line := load_biomes("data/biomes.txt", materials)
	if !testing.expectf(t, err == .None, "biomes must load, got %v at line %d", err, line) {
		destroy_material_table(materials)
		return {}, false
	}

	// create_missing is off: tests read the authored tiles and never
	// write to the working tree.
	tiles, tile_result, _ := load_tile_set(biomes, materials, false)
	if !testing.expectf(t, tile_result.err == .None, "tiles must load, got %v", tile_result.err) {
		destroy_biome_table(biomes)
		destroy_material_table(materials)
		return {}, false
	}

	// A small painted map: Sky on top, Coalmine under it, a Lake to
	// the right of the mine, and one region left empty on purpose.
	m := make_biome_map(4, 3)
	sky, _ := find_biome_index(biomes, "Sky")
	mine, _ := find_biome_index(biomes, "Coalmine")
	lake, _ := find_biome_index(biomes, "Lake")
	for x in i32(0) ..< 4 do biome_map_set(m, x, 0, Biome_Id(sky))
	biome_map_set(m, 0, 1, Biome_Id(mine))
	biome_map_set(m, 1, 1, Biome_Id(mine))
	biome_map_set(m, 2, 1, Biome_Id(lake))

	return World {
			materials = materials,
			biomes = biomes,
			biome_map = m,
			tiles = tiles,
			seed = 12345,
		},
		true
}

@(private = "file")
destroy_test_world :: proc(world: World) {
	destroy_tile_set(world.tiles)
	destroy_biome_map(world.biome_map)
	destroy_biome_table(world.biomes)
	destroy_material_table(world.materials)
}

@(test)
test_floor_div_handles_negative_coordinates :: proc(t: ^testing.T) {
	testing.expect(t, floor_div(0, 512) == 0)
	testing.expect(t, floor_div(511, 512) == 0)
	testing.expect(t, floor_div(512, 512) == 1)
	testing.expect(t, floor_div(-1, 512) == -1, "the cell left of zero is in region -1")
	testing.expect(t, floor_div(-512, 512) == -1)
	testing.expect(t, floor_div(-513, 512) == -2)
}

@(test)
test_generate_is_deterministic :: proc(t: ^testing.T) {
	world, ok := make_test_world(t)
	if !ok do return
	defer destroy_test_world(world)

	view := World_View{x = -700, y = -300, w = 240, h = 160, step = 3}

	a := make([]Cell, int(view.w) * int(view.h))
	b := make([]Cell, int(view.w) * int(view.h))
	defer delete(a)
	defer delete(b)

	generate(world, view, a)
	generate(world, view, b)
	testing.expect(t, slice.equal(a, b), "the same request must give the same world")
}

@(test)
test_generate_matches_the_plain_version :: proc(t: ^testing.T) {
	world, ok := make_test_world(t)
	if !ok do return
	defer destroy_test_world(world)

	// Views that straddle region edges, the world origin, and the edge
	// of the painted map.
	views := []World_View {
		{x = 0, y = 0, w = 64, h = 64, step = 1},
		{x = 500, y = 500, w = 64, h = 64, step = 1}, // crosses a region edge
		{x = -1, y = -1, w = 8, h = 8, step = 1}, // crosses the origin
		{x = -1200, y = -900, w = 96, h = 96, step = 7},
		{x = 0, y = 0, w = 200, h = 120, step = 16}, // pulled back, whole regions
		{x = 511, y = 511, w = 3, h = 3, step = 1}, // corner of four regions
		{x = 3000, y = 40, w = 40, h = 40, step = 5}, // past the painted map
	}

	for view in views {
		fast := make([]Cell, int(view.w) * int(view.h))
		slow := make([]Cell, int(view.w) * int(view.h))
		defer delete(fast)
		defer delete(slow)

		generate(world, view, fast)
		generate_naive(world, view, slow)
		testing.expectf(
			t,
			slice.equal(fast, slow),
			"run fill must match the plain version for view %v",
			view,
		)
	}
}

@(test)
test_generate_fills_regions_from_the_map :: proc(t: ^testing.T) {
	world, ok := make_test_world(t)
	if !ok do return
	defer destroy_test_world(world)

	air, _ := find_material_index(world.materials, "Air")
	water, _ := find_material_index(world.materials, "Water")
	rock, _ := find_material_index(world.materials, "Rock") // the off-map fill

	// Which biome owns a cell is asked separately from what the cell
	// holds. A tile biome paints many materials, so ownership is the
	// thing this test is about.
	owner :: proc(world: World, wx, wy: i32) -> string {
		return world.biomes.names[world_biome_at(world, wx, wy)]
	}

	// origin_pixel is 8 8 in the data file, but the test map is 4x3,
	// so world cell (0,0) sits outside it and reads as off-map.
	testing.expect(t, owner(world, 0, 0) == "Deep_Rock", "outside the map is the off-map biome")
	testing.expect(t, world_cell_at(world, 0, 0) == Cell(rock))

	// Map pixel (px,py) covers world cells starting at
	// (px - origin_x) * 512.
	cpp := world.biomes.cells_per_pixel
	ox := world.biomes.origin_pixel_x
	oy := world.biomes.origin_pixel_y

	sky_x := (0 - ox) * cpp + 10
	sky_y := (0 - oy) * cpp + 10
	testing.expect(t, owner(world, sky_x, sky_y) == "Sky", "map pixel (0,0) is Sky")
	testing.expect(t, world_cell_at(world, sky_x, sky_y) == Cell(air), "Sky fills flat with Air")

	mine_y := (1 - oy) * cpp + 10
	testing.expect(t, owner(world, sky_x, mine_y) == "Coalmine", "map pixel (0,1) is Coalmine")

	lake_x := (2 - ox) * cpp + 10
	testing.expect(t, owner(world, lake_x, mine_y) == "Lake", "map pixel (2,1) is Lake")
	testing.expect(t, world_cell_at(world, lake_x, mine_y) == Cell(water), "Lake fills flat")

	// Pixel (3,1) is inside the map but unpainted, so it is off-map.
	empty_x := (3 - ox) * cpp + 10
	testing.expect(t, owner(world, empty_x, mine_y) == "Deep_Rock", "unpainted pixels fall back")

	// A region edge is sharp: the biome changes at the edge cell, not
	// one cell early or late.
	edge_x := (1 - ox) * cpp
	testing.expect(t, owner(world, edge_x - 1, mine_y) == "Coalmine")
	testing.expect(t, owner(world, edge_x, mine_y) == "Coalmine")
	edge2_x := (2 - ox) * cpp
	testing.expect(t, owner(world, edge2_x - 1, mine_y) == "Coalmine")
	testing.expect(t, owner(world, edge2_x, mine_y) == "Lake", "the border is a hard cut")
}

/*
A tile biome shows its tile, and it shows the same tile in every
region it owns. This is the phase in one test: what the author paints
into the tile is what the world holds.
*/
@(test)
test_tile_biome_repeats_its_tile_through_the_world :: proc(t: ^testing.T) {
	world, ok := make_test_world(t)
	if !ok do return
	defer destroy_test_world(world)

	mine, found := find_biome_index(world.biomes, "Coalmine")
	if !testing.expect(t, found, "Coalmine must exist") do return
	tile := world.biomes.biomes[mine].tile
	if !testing.expect(t, tile != TILE_NONE, "Coalmine must own a tile") do return

	cpp := world.biomes.cells_per_pixel
	ox := world.biomes.origin_pixel_x
	oy := world.biomes.origin_pixel_y

	// Map pixels (0,1) and (1,1) are both Coalmine, and they sit side
	// by side. The tile wraps in world space, so the pattern must run
	// straight through the border between them.
	left_x := (0 - ox) * cpp
	right_x := (1 - ox) * cpp
	base_y := (1 - oy) * cpp

	for i in i32(0) ..< i32(300) {
		wx := left_x + i
		wy := base_y + 7
		testing.expectf(
			t,
			world_cell_at(world, wx, wy) == tile_sample(world.tiles, tile, wx, wy),
			"a Coalmine cell must come from the Coalmine tile at %d,%d",
			wx,
			wy,
		)
	}

	// The seam between the two regions carries the tile through with no
	// break, because the wrap never asks which region it is in.
	for d in i32(-40) ..< i32(40) {
		wx := right_x + d
		wy := base_y + 21
		testing.expectf(
			t,
			world_cell_at(world, wx, wy) == tile_sample(world.tiles, tile, wx, wy),
			"the tile must cross the region seam at %d",
			wx,
		)
	}

	// The tile is authored, not flat. If it were flat, every test above
	// would pass while saying nothing.
	first := tile_cells(world.tiles, tile)[0]
	varied := false
	for c in tile_cells(world.tiles, tile) {
		if c != first {
			varied = true
			break
		}
	}
	testing.expect(t, varied, "the shipped Coalmine tile must hold more than one material")
}

/*
The editor regenerates from the map it holds in memory. The game
regenerates from the map it loaded from disk. These must agree, or
what the author paints is not what the player gets.
*/
@(test)
test_live_map_matches_saved_map :: proc(t: ^testing.T) {
	world, ok := make_test_world(t)
	if !ok do return
	defer destroy_test_world(world)

	path := "worldgen_live_vs_saved.tmp.png"
	defer os.remove(path)
	testing.expect(t, save_biome_map_png(world.biome_map, world.biomes, path))

	loaded, result := load_biome_map_png(path, world.biomes)
	testing.expectf(t, result.err == .None, "reload must succeed, got %v", result.err)
	defer destroy_biome_map(loaded)

	from_disk := world
	from_disk.biome_map = loaded

	view := World_View{x = -2000, y = -1500, w = 128, h = 96, step = 9}
	live := make([]Cell, int(view.w) * int(view.h))
	saved := make([]Cell, int(view.w) * int(view.h))
	defer delete(live)
	defer delete(saved)

	generate(world, view, live)
	generate(from_disk, view, saved)
	testing.expect(t, slice.equal(live, saved), "live edit and saved file must generate alike")
}
