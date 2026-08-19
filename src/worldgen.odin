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

There are two generators. Uniform makes a region one flat material.
Wang cuts the world into a lattice of tile squares and draws one tile
of the biome's set in each of them. Which tile that is comes from the
colors of the four lattice edges around the square, and those colors
come from a hash of their own position. Two squares beside each other
therefore agree about the edge they share without either of them
being generated first.

The shape of this proc has not changed since the flat fill: only the
body of the per-region run changed. That is the point of keeping the
biome lookup and the run loop apart from what fills the run.
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
	seed:      u64, // colors the tile lattice; change it for another world
}

/*
A request for a rectangle of world.

`step` is how many world cells one output texel covers. It is 1 for
the native view. Larger values sample a wider area into the same
buffer, which lets the camera pull back and show whole regions. The
uniform generator is exact at any step, because a sample never
misses detail that is not there.

A tiled biome is not exact above step 1. The view point samples the
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
Which tile of a biome's set covers a world cell.

The lattice is in world space, so the answer does not depend on which
region the cell is in, and a run of the same biome across a region
border carries the pattern straight through. Where the biome does
change the world cuts, and a hard border is what the phase asks for.
*/
world_tile_at :: proc(world: World, b: Biome, wx, wy: i32) -> Tile_Id {
	return wang_tile_at(world.seed, b, tile_slot(wx), tile_slot(wy))
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
	if b.tile_base == TILE_NONE do return Cell(b.fill_0)

	tile := world_tile_at(world, b, wx, wy)
	return tile_at(world.tiles, tile, tile_cell(wx), tile_cell(wy))
}

/*
Generate a view into a caller-owned buffer. There is no chunk store:
a chunk is only how much the caller asks for.

The inner loop works one run at a time, because the lookups cost the
same for one cell as for a thousand. A run reaches to the next thing
that could change what fills it: the region border for a flat biome,
and the nearer of the region border and the tile border for a tiled
one. Both write the same run of texels, so the loop that finds the
run is shared.
*/
generate :: proc(world: World, view: World_View, out: []Cell) {
	assert(view.step >= 1, "step must be 1 or more")
	assert(len(out) >= int(view.w) * int(view.h), "output buffer is too small")

	cpp := world.biomes.cells_per_pixel

	for ty in 0 ..< view.h {
		wy := view.y + ty * view.step
		map_y := floor_div(wy, cpp) + world.biomes.origin_pixel_y
		slot_y := tile_slot(wy)
		row := out[int(ty) * int(view.w):][:view.w]

		tx: i32 = 0
		for tx < view.w {
			wx := view.x + tx * view.step
			region_x := floor_div(wx, cpp)
			map_x := region_x + world.biomes.origin_pixel_x

			id := biome_map_at(world.biome_map, map_x, map_y)
			if id == BIOME_EMPTY do id = world.biomes.off_map_biome
			b := world.biomes.biomes[id]

			// The run cannot outlast the region, because the biome
			// changes there.
			limit := (region_x + 1) * cpp
			slot_x := tile_slot(wx)
			if b.tile_base != TILE_NONE {
				// Nor the tile square, because the tile changes there.
				limit = min(limit, (slot_x + 1) * TILE_SPAN)
			}

			tx_end := ceil_div(limit - view.x, view.step)
			tx_end = clamp(tx_end, tx + 1, view.w)

			if b.tile_base == TILE_NONE {
				slice.fill(row[tx:tx_end], Cell(b.fill_0))
			} else {
				// One row of one tile. The tile and the y wrap are the
				// same for every texel in the run, so both are lifted out
				// of the loop.
				tile := wang_tile_at(world.seed, b, slot_x, slot_y)
				tile_row := tile_cells(world.tiles, tile)[int(tile_cell(wy)) * TILE_SIZE:][:TILE_SIZE]
				for t in tx ..< tx_end {
					row[t] = tile_row[tile_cell(view.x + t * view.step)]
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
			seed = biomes.world_seed,
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

	/*
	Views that straddle region edges, tile edges, the world origin, and
	the edge of the painted map.

	The second group sits inside the painted map, where Coalmine draws
	a set. Without those, every view here reads off-map, every biome is
	uniform, and the tile branch of the run fill is never compared with
	the oracle at all. The unaligned starts matter most: a view whose x
	is a whole number of tiles would hide an error in the run offset,
	and a step wider than a tile would hide a run that fails to stop at
	the tile border.

	Map pixels (0,1) and (1,1) are Coalmine, so world x -4096 to -3072
	at y -3584 to -3072 is tiled. Lake starts at x -3072.
	*/
	views := []World_View {
		{x = 0, y = 0, w = 64, h = 64, step = 1},
		{x = 500, y = 500, w = 64, h = 64, step = 1}, // crosses a region edge
		{x = -1, y = -1, w = 8, h = 8, step = 1}, // crosses the origin
		{x = -1200, y = -900, w = 96, h = 96, step = 7},
		{x = 0, y = 0, w = 200, h = 120, step = 16}, // pulled back, whole regions
		{x = 511, y = 511, w = 3, h = 3, step = 1}, // corner of four regions
		{x = 3000, y = 40, w = 40, h = 40, step = 5}, // past the painted map

		// Inside a tiled biome.
		{x = -4096, y = -3584, w = 128, h = 64, step = 1}, // tile-aligned start
		{x = -4090, y = -3580, w = 200, h = 64, step = 1}, // unaligned start
		{x = -4091, y = -3577, w = 96, h = 48, step = 3}, // unaligned, strided
		{x = -3100, y = -3400, w = 128, h = 64, step = 1}, // tiled into flat Lake
		{x = -4200, y = -3600, w = 256, h = 128, step = 5}, // off-map into tiled
		{x = -3590, y = -3590, w = 64, h = 64, step = 1}, // corner of four regions
		{x = -4096, y = -3584, w = 160, h = 80, step = 9}, // pulled back over tiles
		{x = -4093, y = -3581, w = 64, h = 64, step = 64}, // one texel per tile
		{x = -4093, y = -3581, w = 48, h = 48, step = 97}, // wider than a tile
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
	// holds. A tiled biome paints many materials, so ownership is the
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
A region border falls on a tile border.

The loader refuses a region that is not a whole number of tiles
across, and this is why: a border in the middle of a tile would cut
the pattern in half, and the cut would move with the origin.
*/
@(test)
test_a_region_is_a_whole_number_of_tiles :: proc(t: ^testing.T) {
	world, ok := make_test_world(t)
	if !ok do return
	defer destroy_test_world(world)

	testing.expect(t, world.biomes.cells_per_pixel % TILE_SPAN == 0)

	cpp := world.biomes.cells_per_pixel
	for px in i32(-3) ..< i32(3) {
		border := px * cpp
		testing.expectf(
			t,
			tile_offset(border) == 0,
			"the region border at %d must be the start of a tile",
			border,
		)
	}
}

/*
The phase in one test: what the author paints into a set is what the
world holds, and the tiles that meet always agree along the edge they
share.
*/
@(test)
test_a_wang_biome_draws_its_set_with_matching_edges :: proc(t: ^testing.T) {
	world, ok := make_test_world(t)
	if !ok do return
	defer destroy_test_world(world)

	mine, found := find_biome_index(world.biomes, "Coalmine")
	if !testing.expect(t, found, "Coalmine must exist") do return
	b := world.biomes.biomes[mine]
	if !testing.expect(t, b.tile_base != TILE_NONE, "Coalmine must own a set") do return

	cpp := world.biomes.cells_per_pixel
	ox := world.biomes.origin_pixel_x
	oy := world.biomes.origin_pixel_y

	// Map pixels (0,1) and (1,1) are both Coalmine, and they sit side
	// by side.
	left_x := (0 - ox) * cpp
	right_x := (1 - ox) * cpp
	base_y := (1 - oy) * cpp

	// Every cell of the two regions comes from the tile the lattice
	// picked for the square it is in.
	for wy := base_y; wy < base_y + 128; wy += 7 {
		for wx := left_x; wx < right_x + 128; wx += 3 {
			tile := world_tile_at(world, b, wx, wy)
			testing.expectf(
				t,
				world_cell_at(world, wx, wy) == tile_at(world.tiles, tile, tile_cell(wx), tile_cell(wy)),
				"a Coalmine cell must come from the tile of its square at %d,%d",
				wx,
				wy,
			)
		}
	}

	// Neighbouring squares carry the same color on the edge they share,
	// including across the border between the two regions.
	used: map[Tile_Id]bool
	defer delete(used)

	for sy in tile_slot(base_y) ..< tile_slot(base_y) + 8 {
		for sx in tile_slot(left_x) ..< tile_slot(right_x) + 8 {
			here := wang_tile_at(world.seed, b, sx, sy)
			right := wang_tile_at(world.seed, b, sx + 1, sy)
			below := wang_tile_at(world.seed, b, sx, sy + 1)
			used[here] = true

			sig_here := wang_signature_of(b, here)
			testing.expectf(
				t,
				wang_east(sig_here) == wang_west(wang_signature_of(b, right)),
				"the tiles at %d,%d and %d,%d disagree about the edge between them",
				sx,
				sy,
				sx + 1,
				sy,
			)
			testing.expectf(
				t,
				wang_south(sig_here) == wang_north(wang_signature_of(b, below)),
				"the tiles at %d,%d and %d,%d disagree about the edge between them",
				sx,
				sy,
				sx,
				sy + 1,
			)
		}
	}

	// A set nobody drew twice would be a repeat, not a lattice.
	testing.expect(t, len(used) > 4, "the world must reach for more than a few tiles of the set")

	// The shipped set is authored, not flat. If it were flat, every
	// test above would pass while saying nothing.
	first := world.tiles.cells[int(b.tile_base) * TILE_AREA]
	varied := false
	for k in 0 ..< wang_set_size(b) {
		for c in tile_cells(world.tiles, b.tile_base + Tile_Id(k)) {
			if c != first do varied = true
		}
	}
	testing.expect(t, varied, "the shipped Coalmine set must hold more than one material")
}

/*
The seams hold in the world, not only in the files.

Where two tiles meet, the cells either side of the border are the ones
the shared edge color says they are. That is what makes the lattice
look drawn rather than assembled.
*/
@(test)
test_the_world_has_no_seam_between_two_tiles :: proc(t: ^testing.T) {
	world, ok := make_test_world(t)
	if !ok do return
	defer destroy_test_world(world)

	mine, _ := find_biome_index(world.biomes, "Coalmine")
	b := world.biomes.biomes[mine]
	if !testing.expect(t, b.tile_base != TILE_NONE) do return

	cpp := world.biomes.cells_per_pixel
	left_x := (0 - world.biomes.origin_pixel_x) * cpp
	base_y := (1 - world.biomes.origin_pixel_y) * cpp

	// The cells beside a border belong to the edge, so any other place
	// in the world with the same edge color holds the same cells. Walk
	// the border of every square and compare it with the first square
	// that used that color.
	seen_column: [WANG_COLORS]bool
	column: [WANG_COLORS][TILE_SPAN]Cell

	// Map pixels (0,1) and (1,1) are the Coalmine, and the walk has to
	// stay inside them: a square over the Lake beside it would answer
	// with a column of flat Water and report a seam that is a biome
	// border. Counted in squares per region, so it holds at any
	// TILE_SCALE.
	per_region := cpp / TILE_SPAN

	for sx in tile_slot(left_x) ..< tile_slot(left_x) + 2 * per_region {
		for sy in tile_slot(base_y) ..< tile_slot(base_y) + per_region {
			color := wang_vertical_edge(world.seed, sx, sy)
			wx := sx * TILE_SPAN // the first column inside this square

			if !seen_column[color] {
				seen_column[color] = true
				for i in i32(0) ..< TILE_SPAN {
					column[color][i] = world_cell_at(world, wx, sy * TILE_SPAN + i)
				}
				continue
			}
			for i in i32(0) ..< TILE_SPAN {
				testing.expectf(
					t,
					world_cell_at(world, wx, sy * TILE_SPAN + i) == column[color][i],
					"the cell at %d,%d does not match the edge color %d it sits on",
					wx,
					sy * TILE_SPAN + i,
					color,
				)
			}
		}
	}

	testing.expect(t, seen_column[0] && seen_column[1], "both edge colors must turn up")
}

/*
The seed lays out the lattice. Two worlds with the same authored data
and a different seed hold the same tiles in different places.
*/
@(test)
test_the_seed_lays_out_the_lattice :: proc(t: ^testing.T) {
	world, ok := make_test_world(t)
	if !ok do return
	defer destroy_test_world(world)

	other := world
	other.seed = world.seed + 1

	cpp := world.biomes.cells_per_pixel
	view := World_View {
		x    = (0 - world.biomes.origin_pixel_x) * cpp,
		y    = (1 - world.biomes.origin_pixel_y) * cpp,
		w    = 256,
		h    = 256,
		step = 1,
	}

	a := make([]Cell, int(view.w) * int(view.h))
	b := make([]Cell, int(view.w) * int(view.h))
	defer delete(a)
	defer delete(b)

	generate(world, view, a)
	generate(other, view, b)
	testing.expect(t, !slice.equal(a, b), "another seed must lay the tiles out differently")
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

/*
The same bargain one level down.

The tile editor paints into the set the running world holds, and Save
writes that set to disk. If the files and the live set ever drew
different worlds, the author would save one thing and the player would
get another.
*/
@(test)
test_live_tile_edit_matches_saved_tiles :: proc(t: ^testing.T) {
	world, ok := make_test_world(t)
	if !ok do return
	defer destroy_test_world(world)

	mine, found := find_biome_index(world.biomes, "Coalmine")
	if !testing.expect(t, found) do return
	b := world.biomes.biomes[mine]
	if !testing.expect(t, b.tile_base != TILE_NONE, "Coalmine must own a set") do return

	// Paint a block in the middle of one tile, the way the editor does
	// on a left-drag, and a seam cell, which reaches a whole group.
	acid, _ := find_material_index(world.materials, "Acid")
	sig := wang_signature(1, 0, 1, 0)
	tile := wang_tile_id(b, sig, 0)
	for y in i32(20) ..< i32(28) {
		for x in i32(20) ..< i32(28) {
			tile_set_cell(world.tiles, tile, x, y, Cell(acid))
		}
	}
	wang_paint_cell(world.tiles, b, sig, 0, TILE_SIZE / 2, Cell(acid))

	// Save the set into a scratch prefix, then read it back into a set
	// of its own and generate from that.
	saved_table := world.biomes
	prefixes := make([]string, len(world.biomes.tile_prefixes))
	defer delete(prefixes)
	copy(prefixes, world.biomes.tile_prefixes)
	prefixes[mine] = "worldgen_set.tmp"
	saved_table.tile_prefixes = prefixes

	written, failed, save_ok := save_tile_set(world.tiles, saved_table, Biome_Id(mine), world.materials)
	testing.expectf(t, save_ok, "the set must save, and %s did not", failed)
	testing.expect(t, written == wang_set_size(b))
	defer {
		for k in 0 ..< wang_set_size(b) {
			os.remove(biome_tile_path(saved_table, Biome_Id(mine), b.tile_base + Tile_Id(k)))
		}
	}

	reloaded, result, _ := load_tile_set(saved_table, world.materials, false)
	testing.expectf(t, result.err == .None, "the set must reload, got %v", result.err)
	defer destroy_tile_set(reloaded)

	from_disk := world
	from_disk.tiles = reloaded

	view := World_View{x = -4096, y = -3584, w = 512, h = 128, step = 1}
	live := make([]Cell, int(view.w) * int(view.h))
	saved := make([]Cell, int(view.w) * int(view.h))
	defer delete(live)
	defer delete(saved)

	generate(world, view, live)
	generate(from_disk, view, saved)
	testing.expect(t, slice.equal(live, saved), "a painted set must save and reload unchanged")
}

/*
Painting a tile changes the biome that owns it, and nothing else.

A set belongs to a biome, not to a region, so the edit must reach
every region of that biome and stop at the border of the next one.
*/
@(test)
test_tile_edit_changes_only_its_own_biome :: proc(t: ^testing.T) {
	world, ok := make_test_world(t)
	if !ok do return
	defer destroy_test_world(world)

	mine, _ := find_biome_index(world.biomes, "Coalmine")
	b := world.biomes.biomes[mine]
	if !testing.expect(t, b.tile_base != TILE_NONE, "Coalmine must own a set") do return

	// The view spans map pixels (0,1) and (1,1), which are both
	// Coalmine, plus the Lake and the unpainted pixel to their right.
	// One texel per four cells, so 512 of them reach across all four.
	view := World_View{x = -4096, y = -3584, w = 512, h = 128, step = 4}
	before := make([]Cell, int(view.w) * int(view.h))
	after := make([]Cell, int(view.w) * int(view.h))
	defer delete(before)
	defer delete(after)

	generate(world, view, before)

	// Every tile of the set, so the change reaches the world wherever
	// the lattice looked.
	acid, _ := find_material_index(world.materials, "Acid")
	for k in 0 ..< wang_set_size(b) {
		for y in i32(20) ..< i32(28) {
			for x in i32(20) ..< i32(28) {
				tile_set_cell(world.tiles, b.tile_base + Tile_Id(k), x, y, Cell(acid))
			}
		}
	}

	generate(world, view, after)

	changed := 0
	regions_touched: map[i32]bool
	defer delete(regions_touched)

	for i in 0 ..< len(before) {
		if before[i] == after[i] do continue
		changed += 1

		tx := i32(i % int(view.w))
		ty := i32(i / int(view.w))
		wx := view.x + tx * view.step
		wy := view.y + ty * view.step

		testing.expectf(
			t,
			world_biome_at(world, wx, wy) == Biome_Id(mine),
			"cell %d,%d changed but belongs to %s",
			wx,
			wy,
			world.biomes.names[world_biome_at(world, wx, wy)],
		)
		regions_touched[floor_div(wx, world.biomes.cells_per_pixel)] = true
	}

	testing.expect(t, changed > 0, "the paint must reach the world at all")
	testing.expect(
		t,
		len(regions_touched) > 1,
		"the set belongs to the biome, so every region of it must change",
	)
}
