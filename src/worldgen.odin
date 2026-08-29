package game

import "core:fmt"
import "core:slice"
import "core:testing"

Cell :: u8

World :: struct {
	materials: Material_Table,
	biomes:    Biome_Table,
	biome_map: Biome_Map,
	tiles:     Tile_Set,
	images:    [][]Cell,
	seed:      u64,

}

World_View :: struct {
	x:    i32,
	y:    i32,
	w:    i32,
	h:    i32,
	step: i32,
}

floor_div :: proc(a, b: i32) -> i32 {
	q := a / b
	if (a % b != 0) && ((a < 0) != (b < 0)) do q -= 1
	return q
}

@(private = "file")
ceil_div :: proc(a, b: i32) -> i32 {
	q := a / b
	if (a % b != 0) && (a > 0) do q += 1
	return q
}

region_offset :: proc(w, cpp: i32) -> i32 {
	return w - floor_div(w, cpp) * cpp
}

world_biome_at :: proc(world: World, wx, wy: i32) -> Biome_Id {
	cpp := world.biomes.cells_per_pixel
	map_x := floor_div(wx, cpp) + world.biomes.origin_pixel_x
	map_y := floor_div(wy, cpp) + world.biomes.origin_pixel_y

	id := biome_map_at(world.biome_map, map_x, map_y)
	if id == BIOME_EMPTY do id = world.biomes.off_map_biome
	return id
}

world_tile_at :: proc(world: World, b: Biome, wx, wy: i32) -> Tile_Id {
	return wang_tile_at(world.seed, b, tile_slot(wx), tile_slot(wy))
}

// Which of an image biome's pictures a region draws. A wang biome picks
// a variant per tile; an image biome picks one per region, off the same
// hash, so a biome six regions long is six drawings out of the set and
// another seed lays out another six.
world_image_variant :: proc(world: World, b: Biome, region_x, region_y: i32) -> int {
	if b.variants <= 1 do return 0
	return int(wang_hash(world.seed, WANG_SALT_VARIANT, region_x, region_y) % u64(b.variants))
}

world_image_cells :: proc(world: World, id: Biome_Id, variant: int) -> []Cell {
	cpp := world.biomes.cells_per_pixel
	area := int(cpp) * int(cpp)
	return world.images[id][variant * area:][:area]
}

world_cell_at :: proc(world: World, wx, wy: i32) -> Cell {
	id := world_biome_at(world, wx, wy)
	b := world.biomes.biomes[id]

	if b.generator == .Image {
		cpp := world.biomes.cells_per_pixel
		img := world_image_cells(world, id, world_image_variant(world, b, floor_div(wx, cpp), floor_div(wy, cpp)))
		return img[int(region_offset(wy, cpp)) * int(cpp) + int(region_offset(wx, cpp))]
	}

	if b.tile_base == TILE_NONE do return Cell(b.fill_0)

	tile := world_tile_at(world, b, wx, wy)
	return tile_at(world.tiles, tile, tile_offset(wx), tile_offset(wy))
}

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

			limit := (region_x + 1) * cpp
			slot_x := tile_slot(wx)
			if b.generator == .Wang {
				limit = min(limit, (slot_x + 1) * TILE_SIZE)
			}

			tx_end := ceil_div(limit - view.x, view.step)
			tx_end = clamp(tx_end, tx + 1, view.w)

			switch b.generator {
			case .Uniform:
				slice.fill(row[tx:tx_end], Cell(b.fill_0))
			case .Wang:
				tile := wang_tile_at(world.seed, b, slot_x, slot_y)
				tile_row := tile_cells(world.tiles, tile)[int(tile_offset(wy)) * TILE_SIZE:][:TILE_SIZE]
				for t in tx ..< tx_end {
					row[t] = tile_row[tile_offset(view.x + t * view.step)]
				}
			case .Image:
				img := world_image_cells(world, id, world_image_variant(world, b, region_x, floor_div(wy, cpp)))
				img_row := img[int(region_offset(wy, cpp)) * int(cpp):][:cpp]
				for t in tx ..< tx_end {
					row[t] = img_row[region_offset(view.x + t * view.step, cpp)]
				}
			}
			tx = tx_end
		}
	}
}

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

	tiles, tile_result, _ := load_tile_set(biomes, materials, false)
	if !testing.expectf(t, tile_result.err == .None, "tiles must load, got %v", tile_result.err) {
		destroy_biome_table(biomes)
		destroy_material_table(materials)
		return {}, false
	}

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

	views := []World_View {
		{x = 0, y = 0, w = 64, h = 64, step = 1},
		{x = 500, y = 500, w = 64, h = 64, step = 1},
		{x = -1, y = -1, w = 8, h = 8, step = 1},
		{x = -1200, y = -900, w = 96, h = 96, step = 7},
		{x = 0, y = 0, w = 200, h = 120, step = 16},
		{x = 511, y = 511, w = 3, h = 3, step = 1},
		{x = 3000, y = 40, w = 40, h = 40, step = 5},

		{x = -4096, y = -3584, w = 128, h = 64, step = 1},
		{x = -4090, y = -3580, w = 200, h = 64, step = 1},
		{x = -4091, y = -3577, w = 96, h = 48, step = 3},
		{x = -3100, y = -3400, w = 128, h = 64, step = 1},
		{x = -4200, y = -3600, w = 256, h = 128, step = 5},
		{x = -3590, y = -3590, w = 64, h = 64, step = 1},
		{x = -4096, y = -3584, w = 160, h = 80, step = 9},
		{x = -4093, y = -3581, w = 64, h = 64, step = 64},
		{x = -4093, y = -3581, w = 48, h = 48, step = 97},
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
	rock, _ := find_material_index(world.materials, "Rock")

	owner :: proc(world: World, wx, wy: i32) -> string {
		return world.biomes.names[world_biome_at(world, wx, wy)]
	}

	testing.expect(t, owner(world, 0, 0) == "Deep_Rock", "outside the map is the off-map biome")
	testing.expect(t, world_cell_at(world, 0, 0) == Cell(rock))

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

	empty_x := (3 - ox) * cpp + 10
	testing.expect(t, owner(world, empty_x, mine_y) == "Deep_Rock", "unpainted pixels fall back")

	edge_x := (1 - ox) * cpp
	testing.expect(t, owner(world, edge_x - 1, mine_y) == "Coalmine")
	testing.expect(t, owner(world, edge_x, mine_y) == "Coalmine")
	edge2_x := (2 - ox) * cpp
	testing.expect(t, owner(world, edge2_x - 1, mine_y) == "Coalmine")
	testing.expect(t, owner(world, edge2_x, mine_y) == "Lake", "the border is a hard cut")
}

@(test)
test_a_region_is_a_whole_number_of_tiles :: proc(t: ^testing.T) {
	world, ok := make_test_world(t)
	if !ok do return
	defer destroy_test_world(world)

	testing.expect(t, world.biomes.cells_per_pixel % TILE_SIZE == 0)

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

	left_x := (0 - ox) * cpp
	right_x := (1 - ox) * cpp
	base_y := (1 - oy) * cpp

	for wy := base_y; wy < base_y + 128; wy += 7 {
		for wx := left_x; wx < right_x + 128; wx += 3 {
			tile := world_tile_at(world, b, wx, wy)
			testing.expectf(
				t,
				world_cell_at(world, wx, wy) == tile_at(world.tiles, tile, tile_offset(wx), tile_offset(wy)),
				"a Coalmine cell must come from the tile of its square at %d,%d",
				wx,
				wy,
			)
		}
	}

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

	testing.expect(t, len(used) > 4, "the world must reach for more than a few tiles of the set")

	first := world.tiles.cells[int(b.tile_base) * TILE_AREA]
	varied := false
	for k in 0 ..< wang_set_size(b) {
		for c in tile_cells(world.tiles, b.tile_base + Tile_Id(k)) {
			if c != first do varied = true
		}
	}
	testing.expect(t, varied, "the shipped Coalmine set must hold more than one material")
}

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

	seen_column: [WANG_COLORS]bool
	column: [WANG_COLORS][TILE_SIZE]Cell

	for px in i32(0) ..< world.biome_map.width {
		for py in i32(0) ..< world.biome_map.height {
			biome_map_set(world.biome_map, px, py, Biome_Id(mine))
		}
	}

	per_region := cpp / TILE_SIZE

	for sx in tile_slot(left_x) ..< tile_slot(left_x) + 4 * per_region {
		for sy in tile_slot(base_y) ..< tile_slot(base_y) + 2 * per_region {
			color := wang_vertical_edge(world.seed, sx, sy)
			wx := sx * TILE_SIZE

			if !seen_column[color] {
				seen_column[color] = true
				for i in i32(0) ..< TILE_SIZE {
					column[color][i] = world_cell_at(world, wx, sy * TILE_SIZE + i)
				}
				continue
			}
			for i in i32(0) ..< TILE_SIZE {
				testing.expectf(
					t,
					world_cell_at(world, wx, sy * TILE_SIZE + i) == column[color][i],
					"the cell at %d,%d does not match the edge color %d it sits on",
					wx,
					sy * TILE_SIZE + i,
					color,
				)
			}
		}
	}

	testing.expect(t, seen_column[0] && seen_column[1], "both edge colors must turn up")
}

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
		w    = 2 * cpp,
		h    = cpp,
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

@(test)
test_live_map_matches_saved_map :: proc(t: ^testing.T) {
	world, ok := make_test_world(t)
	if !ok do return
	defer destroy_test_world(world)

	path := "worldgen_live_vs_saved.tmp.png"
	defer file_remove(path)
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

@(test)
test_live_tile_edit_matches_saved_tiles :: proc(t: ^testing.T) {
	world, ok := make_test_world(t)
	if !ok do return
	defer destroy_test_world(world)

	mine, found := find_biome_index(world.biomes, "Coalmine")
	if !testing.expect(t, found) do return
	b := world.biomes.biomes[mine]
	if !testing.expect(t, b.tile_base != TILE_NONE, "Coalmine must own a set") do return

	acid, _ := find_material_index(world.materials, "Acid")
	sig := wang_signature(1, 0, 1, 0)
	tile := wang_tile_id(b, sig, 0)
	for y in i32(20) ..< i32(28) {
		for x in i32(20) ..< i32(28) {
			tile_set_cell(world.tiles, tile, x, y, Cell(acid))
		}
	}
	wang_paint_cell(world.tiles, b, sig, 0, TILE_SIZE / 2, Cell(acid))

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
			file_remove(biome_tile_path(saved_table, Biome_Id(mine), b.tile_base + Tile_Id(k)))
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

@(test)
test_tile_edit_changes_only_its_own_biome :: proc(t: ^testing.T) {
	world, ok := make_test_world(t)
	if !ok do return
	defer destroy_test_world(world)

	mine, _ := find_biome_index(world.biomes, "Coalmine")
	b := world.biomes.biomes[mine]
	if !testing.expect(t, b.tile_base != TILE_NONE, "Coalmine must own a set") do return

	view := World_View{x = -4096, y = -3584, w = 512, h = 128, step = 4}
	before := make([]Cell, int(view.w) * int(view.h))
	after := make([]Cell, int(view.w) * int(view.h))
	defer delete(before)
	defer delete(after)

	generate(world, view, before)

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

@(private = "file")
IMAGE_TEST_PREFIX :: "worldgen_image_biome.tmp"
@(private = "file")
IMAGE_TEST_PNG :: IMAGE_TEST_PREFIX + "_0.png"
@(private = "file")
IMAGE_TEST_TXT :: "worldgen_image_biome.tmp.txt"

@(private = "file")
make_image_test_world :: proc(t: ^testing.T) -> (world: World, painted: []Cell, ok: bool) {
	materials, mat_ok := load_materials("data/materials.txt")
	if !testing.expect(t, mat_ok, "materials must load") do return {}, nil, false

	rock, _ := find_material_index(materials, "Rock")
	air, _ := find_material_index(materials, "Air")
	gold, _ := find_material_index(materials, "Gold")

	painted = make([]Cell, TILE_AREA)
	slice.fill(painted, Cell(rock))
	painted[0] = Cell(air)
	painted[TILE_SIZE - 1] = Cell(gold)
	painted[(TILE_SIZE - 1) * TILE_SIZE] = Cell(gold)
	painted[(TILE_SIZE - 1) * TILE_SIZE + TILE_SIZE - 1] = Cell(air)
	painted[100 * TILE_SIZE + 40] = Cell(gold)

	if !testing.expect(t, save_tile_png(painted, materials, IMAGE_TEST_PNG), "the fixture must save") {
		delete(painted)
		destroy_material_table(materials)
		return {}, nil, false
	}
	defer file_remove(IMAGE_TEST_PNG)

	body := fmt.tprintf(
		"[Map]\nbiome_off_map = Ground\norigin_pixel = 1 0\ncells_per_pixel = %d\n" +
		"[Ground]\ncolor = 0xFF000001\nfill_0 = Rock\n" +
		"[Gallery]\ncolor = 0xFF000002\nfill_0 = Rock\ngenerator = image\nimage = %s\n",
		TILE_SIZE, IMAGE_TEST_PREFIX,
	)
	if !testing.expect(t, file_write(IMAGE_TEST_TXT, transmute([]byte)body), "write temp biomes.txt") {
		delete(painted)
		destroy_material_table(materials)
		return {}, nil, false
	}
	defer file_remove(IMAGE_TEST_TXT)

	biomes, err, line := load_biomes(IMAGE_TEST_TXT, materials)
	if !testing.expectf(t, err == .None, "biomes must load, got %v at line %d", err, line) {
		delete(painted)
		destroy_material_table(materials)
		return {}, nil, false
	}

	images, img_result, bad_biome := load_image_set(biomes, materials)
	if !testing.expectf(t, img_result.err == .None, "images must load, got %v for biome %d", img_result.err, bad_biome) {
		delete(painted)
		destroy_biome_table(biomes)
		destroy_material_table(materials)
		return {}, nil, false
	}

	gallery, gallery_found := find_biome_index(biomes, "Gallery")
	ground, ground_found := find_biome_index(biomes, "Ground")
	if !testing.expect(t, gallery_found && ground_found, "both biomes must load") {
		delete(painted)
		destroy_image_set(images)
		destroy_biome_table(biomes)
		destroy_material_table(materials)
		return {}, nil, false
	}

	m := make_biome_map(2, 1)
	biome_map_set(m, 0, 0, Biome_Id(gallery))
	biome_map_set(m, 1, 0, Biome_Id(ground)) 

	world = World {
		materials = materials,
		biomes    = biomes,
		biome_map = m,
		tiles     = make_tile_set(0),
		images    = images,
		seed      = biomes.world_seed,
	}
	return world, painted, true
}

@(private = "file")
destroy_image_test_world :: proc(world: World, painted: []Cell) {
	delete(painted)
	destroy_tile_set(world.tiles)
	destroy_image_set(world.images)
	destroy_biome_map(world.biome_map)
	destroy_biome_table(world.biomes)
	destroy_material_table(world.materials)
}

@(test)
test_image_biome_generates_the_painted_picture :: proc(t: ^testing.T) {
	world, painted, ok := make_image_test_world(t)
	if !ok do return
	defer destroy_image_test_world(world, painted)

	for ly in i32(0) ..< TILE_SIZE {
		for lx in i32(0) ..< TILE_SIZE {
			wx := lx - TILE_SIZE
			wy := ly
			testing.expectf(
				t,
				world_cell_at(world, wx, wy) == painted[ly * TILE_SIZE + lx],
				"cell %d,%d must be what the picture painted at %d,%d",
				wx, wy, lx, ly,
			)
		}
	}
}

@(test)
test_generate_matches_naive_across_a_border_into_an_image_biome :: proc(t: ^testing.T) {
	world, painted, ok := make_image_test_world(t)
	if !ok do return
	defer destroy_image_test_world(world, painted)

	views := []World_View {
		{x = -40, y = 10, w = 80, h = 64, step = 1},
		{x = -37, y = 3, w = 90, h = 48, step = 3},
		{x = -TILE_SIZE, y = 0, w = TILE_SIZE, h = 64, step = 5},
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
			"run fill must match the plain version for view %v crossing into an image biome",
			view,
		)
	}
}
