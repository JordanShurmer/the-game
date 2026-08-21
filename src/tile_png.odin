package game

import "core:os"
import "core:strings"
import "core:testing"
import rl "vendor:raylib"

Tile_Load_Error :: enum u8 {
	None,
	File_Unreadable,
	Wrong_Size,     
	Unmatched_Color,
}

Tile_Load_Result :: struct {
	color: u32,
	x:     i32,
	y:     i32,
	err:   Tile_Load_Error,
}

load_tile_png :: proc(path: string, materials: Material_Table, dst: []Cell, size: i32 = TILE_SIZE) -> Tile_Load_Result {
	assert(len(dst) == int(size) * int(size), "a tile buffer must hold size*size cells")

	if !os.exists(path) {
		return {err = .File_Unreadable}
	}

	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	defer delete(cpath, context.temp_allocator)

	img := rl.LoadImage(cpath)
	if img.data == nil || img.width <= 0 || img.height <= 0 {
		return {err = .File_Unreadable}
	}
	defer rl.UnloadImage(img)

	if img.width != size || img.height != size {
		return {err = .Wrong_Size, x = img.width, y = img.height}
	}

	pixels := rl.LoadImageColors(img)
	defer rl.UnloadImageColors(pixels)

	for y in i32(0) ..< size {
		for x in i32(0) ..< size {
			argb := argb_from_rl(pixels[int(y) * int(size) + int(x)])
			idx, found := find_material_by_color(materials, argb)
			if !found {
				return {err = .Unmatched_Color, color = argb, x = x, y = y}
			}
			dst[int(y) * int(size) + int(x)] = Cell(idx)
		}
	}

	return {}
}

save_tile_png :: proc(cells: []Cell, materials: Material_Table, path: string) -> bool {
	assert(len(cells) == TILE_AREA, "a tile buffer is TILE_AREA cells")

	pixels := make([]rl.Color, TILE_AREA, context.temp_allocator)
	defer delete(pixels, context.temp_allocator)

	for c, i in cells {
		pixels[i] = rl_from_argb(materials.materials[c].color)
	}

	img := rl.Image {
		data    = raw_data(pixels),
		width   = TILE_SIZE,
		height  = TILE_SIZE,
		mipmaps = 1,
		format  = .UNCOMPRESSED_R8G8B8A8,
	}

	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	defer delete(cpath, context.temp_allocator)

	return bool(rl.ExportImage(img, cpath))
}

load_tile_set :: proc(
	biomes: Biome_Table,
	materials: Material_Table,
	create_missing: bool,
	allocator := context.allocator,
) -> (
	set: Tile_Set,
	result: Tile_Load_Result,
	bad_tile: Tile_Id,
) {
	set = make_tile_set(biome_tile_count(biomes), allocator)

	for b, i in biomes.biomes {
		if b.tile_base == TILE_NONE do continue

		for k in 0 ..< wang_set_size(b) {
			tile := b.tile_base + Tile_Id(k)
			path := biome_tile_path(biomes, Biome_Id(i), tile)
			cells := tile_cells(set, tile)

			if os.exists(path) {
				r := load_tile_png(path, materials, cells)
				if r.err != .None {
					destroy_tile_set(set, allocator)
					return {}, r, tile
				}
				continue
			}

			tile_fill(set, tile, Cell(b.fill_0))
			if create_missing {
				if !save_tile_png(cells, materials, path) {
					destroy_tile_set(set, allocator)
					return {}, {err = .File_Unreadable}, tile
				}
			}
		}
	}

	return set, {}, TILE_NONE
}

load_image_set :: proc(
	biomes: Biome_Table,
	materials: Material_Table,
	allocator := context.allocator,
) -> (
	images: [][]Cell,
	result: Tile_Load_Result,
	bad_biome: Biome_Id,
) {
	images = make([][]Cell, len(biomes.biomes), allocator)
	size := biomes.cells_per_pixel

	for b, i in biomes.biomes {
		if b.generator != .Image do continue

		cells := make([]Cell, int(size) * int(size), allocator)
		r := load_tile_png(biomes.image_paths[i], materials, cells, size)
		if r.err != .None {
			delete(cells, allocator)
			destroy_image_set(images, allocator)
			return nil, r, Biome_Id(i)
		}
		images[i] = cells
	}

	return images, {}, BIOME_EMPTY
}

destroy_image_set :: proc(images: [][]Cell, allocator := context.allocator) {
	for img in images do delete(img, allocator)
	delete(images, allocator)
}

save_tile_set :: proc(
	set: Tile_Set,
	biomes: Biome_Table,
	biome: Biome_Id,
	materials: Material_Table,
) -> (
	written: int,
	failed_path: string,
	ok: bool,
) {
	b := biomes.biomes[biome]
	if b.tile_base == TILE_NONE do return 0, "", true

	for k in 0 ..< wang_set_size(b) {
		tile := b.tile_base + Tile_Id(k)
		path := biome_tile_path(biomes, biome, tile)
		if !save_tile_png(tile_cells(set, tile), materials, path) {
			return written, path, false
		}
		written += 1
	}
	return written, "", true
}

@(private = "file")
load_png_test_tables :: proc(
	t: ^testing.T,
) -> (
	materials: Material_Table,
	biomes: Biome_Table,
	ok: bool,
) {
	mat_ok: bool
	materials, mat_ok = load_materials("data/materials.txt")
	if !testing.expect(t, mat_ok, "materials must load") do return {}, {}, false

	err: Biome_Load_Error
	line: int
	biomes, err, line = load_biomes("data/biomes.txt", materials)
	if !testing.expectf(t, err == .None, "biomes must load, got %v at line %d", err, line) {
		destroy_material_table(materials)
		return {}, {}, false
	}
	return materials, biomes, true
}

@(test)
test_tile_png_round_trip :: proc(t: ^testing.T) {
	materials, biomes, ok := load_png_test_tables(t)
	if !ok do return
	defer destroy_biome_table(biomes)
	defer destroy_material_table(materials)

	set := make_tile_set(1)
	defer destroy_tile_set(set)

	air, _ := find_material_index(materials, "Air")
	rock, _ := find_material_index(materials, "Rock")
	gold, _ := find_material_index(materials, "Gold")

	tile_fill(set, 0, Cell(rock))
	tile_set_cell(set, 0, 0, 0, Cell(air))
	tile_set_cell(set, 0, 3, 9, Cell(gold))
	tile_set_cell(set, 0, TILE_SIZE - 1, TILE_SIZE - 1, Cell(air))

	path := "tile_round_trip.tmp.png"
	defer os.remove(path)
	testing.expect(t, save_tile_png(tile_cells(set, 0), materials, path), "save must succeed")

	loaded := make_tile_set(1)
	defer destroy_tile_set(loaded)

	r := load_tile_png(path, materials, tile_cells(loaded, 0))
	testing.expectf(t, r.err == .None, "load must succeed, got %v", r.err)
	for c, i in tile_cells(set, 0) {
		testing.expectf(t, tile_cells(loaded, 0)[i] == c, "cell %d changed on the way back", i)
	}
}

@(test)
test_tile_png_unmatched_color_is_an_error :: proc(t: ^testing.T) {
	materials, mat_ok := load_materials("data/materials.txt")
	testing.expect(t, mat_ok)
	defer destroy_material_table(materials)

	pixels := make([]rl.Color, TILE_AREA, context.temp_allocator)
	defer delete(pixels, context.temp_allocator)
	for &p in pixels do p = rl_from_argb(materials.materials[0].color)
	pixels[5 * TILE_SIZE + 2] = rl.Color{1, 2, 3, 255}

	img := rl.Image {
		data    = raw_data(pixels),
		width   = TILE_SIZE,
		height  = TILE_SIZE,
		mipmaps = 1,
		format  = .UNCOMPRESSED_R8G8B8A8,
	}
	path := "tile_bad_color.tmp.png"
	defer os.remove(path)
	testing.expect(t, bool(rl.ExportImage(img, strings.clone_to_cstring(path, context.temp_allocator))))

	dst := make([]Cell, TILE_AREA)
	defer delete(dst)

	r := load_tile_png(path, materials, dst)
	testing.expect(t, r.err == .Unmatched_Color, "unknown colors are a hard error")
	testing.expect(t, r.color == 0xFF010203, "the report names the bad color")
	testing.expect(t, r.x == 2 && r.y == 5, "the report names the bad pixel")
}

@(test)
test_tile_png_wrong_size_is_an_error :: proc(t: ^testing.T) {
	materials, mat_ok := load_materials("data/materials.txt")
	testing.expect(t, mat_ok)
	defer destroy_material_table(materials)

	pixels := []rl.Color{{0, 0, 0, 0}, {0, 0, 0, 0}}
	img := rl.Image {
		data    = raw_data(pixels),
		width   = 2,
		height  = 1,
		mipmaps = 1,
		format  = .UNCOMPRESSED_R8G8B8A8,
	}
	path := "tile_wrong_size.tmp.png"
	defer os.remove(path)
	testing.expect(t, bool(rl.ExportImage(img, strings.clone_to_cstring(path, context.temp_allocator))))

	dst := make([]Cell, TILE_AREA)
	defer delete(dst)

	r := load_tile_png(path, materials, dst)
	testing.expect(t, r.err == .Wrong_Size, "a tile must be TILE_SIZE square")
	testing.expect(t, r.x == 2 && r.y == 1, "the report names the size it found")
}

@(test)
test_tile_png_missing_file_is_an_error :: proc(t: ^testing.T) {
	materials, mat_ok := load_materials("data/materials.txt")
	testing.expect(t, mat_ok)
	defer destroy_material_table(materials)

	dst := make([]Cell, TILE_AREA)
	defer delete(dst)

	r := load_tile_png("data/tiles/no_such_tile.png", materials, dst)
	testing.expect(t, r.err == .File_Unreadable)
}

@(test)
test_load_image_set_refuses_the_wrong_size :: proc(t: ^testing.T) {
	materials, mat_ok := load_materials("data/materials.txt")
	testing.expect(t, mat_ok)
	defer destroy_material_table(materials)

	rock, _ := find_material_index(materials, "Rock")

	pixels := []rl.Color{{0, 0, 0, 0}, {0, 0, 0, 0}}
	img := rl.Image {
		data    = raw_data(pixels),
		width   = 2,
		height  = 1,
		mipmaps = 1,
		format  = .UNCOMPRESSED_R8G8B8A8,
	}
	path := "image_wrong_size.tmp.png"
	defer os.remove(path)
	testing.expect(t, bool(rl.ExportImage(img, strings.clone_to_cstring(path, context.temp_allocator))))

	table := Biome_Table {
		biomes          = []Biome{{fill_0 = u16(rock), tile_base = TILE_NONE, generator = .Image, variants = 0}},
		image_paths     = []string{path},
		cells_per_pixel = TILE_SIZE,
	}

	images, result, bad := load_image_set(table, materials, context.temp_allocator)
	testing.expect(t, result.err == .Wrong_Size, "the image must be cells_per_pixel square")
	testing.expect(t, result.x == 2 && result.y == 1, "the report names the size it found")
	testing.expect(t, bad == 0, "the report names the biome that failed")
	testing.expect(t, images == nil)
}

@(test)
test_load_tile_set_reads_every_authored_tile :: proc(t: ^testing.T) {
	materials, biomes, ok := load_png_test_tables(t)
	if !ok do return
	defer destroy_biome_table(biomes)
	defer destroy_material_table(materials)

	set, result, id := load_tile_set(biomes, materials, false)
	testing.expectf(
		t,
		result.err == .None,
		"tile %d failed to load: %v at %d,%d",
		id,
		result.err,
		result.x,
		result.y,
	)
	defer destroy_tile_set(set)

	testing.expect(t, set.count == biome_tile_count(biomes))
	testing.expect(t, set.count > 0, "the shipped data must author at least one set")

	for c in set.cells {
		testing.expectf(t, int(c) < len(materials.materials), "cell holds unknown material %d", c)
	}
}

@(test)
test_the_shipped_sets_have_no_seam_conflict :: proc(t: ^testing.T) {
	materials, biomes, ok := load_png_test_tables(t)
	if !ok do return
	defer destroy_biome_table(biomes)
	defer destroy_material_table(materials)

	set, result, _ := load_tile_set(biomes, materials, false)
	if !testing.expectf(t, result.err == .None, "the sets must load, got %v", result.err) do return
	defer destroy_tile_set(set)

	sets := 0
	for b, i in biomes.biomes {
		if b.tile_base == TILE_NONE do continue
		sets += 1

		conflict := wang_find_conflict(set, b)
		testing.expectf(
			t,
			!conflict.found,
			"%s: tiles %d and %d disagree at cell %d,%d",
			biomes.names[i],
			conflict.a,
			conflict.b,
			conflict.x,
			conflict.y,
		)
	}
	testing.expect(t, sets > 0, "the shipped data must author at least one set")
}

@(test)
test_the_shipped_sets_are_about_half_air :: proc(t: ^testing.T) {
	materials, biomes, ok := load_png_test_tables(t)
	if !ok do return
	defer destroy_biome_table(biomes)
	defer destroy_material_table(materials)

	set, result, _ := load_tile_set(biomes, materials, false)
	if !testing.expectf(t, result.err == .None, "the sets must load, got %v", result.err) do return
	defer destroy_tile_set(set)

	air, _ := find_material_index(materials, "Air")

	for b, i in biomes.biomes {
		if b.tile_base == TILE_NONE do continue

		open := 0
		for k in 0 ..< wang_set_size(b) {
			for c in tile_cells(set, b.tile_base + Tile_Id(k)) {
				if int(c) == air do open += 1
			}
		}

		percent := 100 * open / (wang_set_size(b) * TILE_AREA)
		testing.expectf(
			t,
			percent >= 35 && percent <= 60,
			"%s is %d%% air, and a cave system is about half",
			biomes.names[i],
			percent,
		)
	}
}

@(test)
test_load_tile_set_fills_a_missing_set_with_the_biome_fill :: proc(t: ^testing.T) {
	materials, mat_ok := load_materials("data/materials.txt")
	testing.expect(t, mat_ok)
	defer destroy_material_table(materials)

	body := "[Map]\nbiome_off_map = A\n[A]\ncolor = 0xFF000001\nfill_0 = Rock\n" +
		"[B]\ncolor = 0xFF000002\nfill_0 = Sand\ngenerator = wang\ntiles = tile_absent.tmp\nvariants = 2\n"
	path := "tile_set_missing.tmp.txt"
	testing.expect(t, os.write_entire_file(path, transmute([]byte)body) == nil)
	defer os.remove(path)

	biomes, err, _ := load_biomes(path, materials)
	testing.expectf(t, err == .None, "the table must load, got %v", err)
	defer destroy_biome_table(biomes)

	set, result, _ := load_tile_set(biomes, materials, false)
	testing.expectf(t, result.err == .None, "a missing set is not an error, got %v", result.err)
	defer destroy_tile_set(set)

	sand, _ := find_material_index(materials, "Sand")
	testing.expect(t, set.count == WANG_SIGNATURES * 2, "the whole set exists, painted or not")
	for c in set.cells {
		testing.expect(t, c == Cell(sand), "a new set starts as the fill of its biome")
	}
	testing.expect(t, !wang_find_conflict(set, biomes.biomes[1]).found, "a flat set has no seam trouble")
	testing.expect(t, !os.exists("tile_absent_0000_0.png"), "create_missing off must write nothing")
}

@(test)
test_tile_set_round_trip :: proc(t: ^testing.T) {
	materials, mat_ok := load_materials("data/materials.txt")
	testing.expect(t, mat_ok)
	defer destroy_material_table(materials)

	body := "[Map]\nbiome_off_map = A\n[A]\ncolor = 0xFF000001\nfill_0 = Rock\n" +
		"[B]\ncolor = 0xFF000002\nfill_0 = Sand\ngenerator = wang\ntiles = tile_trip.tmp\n"
	path := "tile_set_trip.tmp.txt"
	testing.expect(t, os.write_entire_file(path, transmute([]byte)body) == nil)
	defer os.remove(path)

	biomes, err, _ := load_biomes(path, materials)
	testing.expectf(t, err == .None, "the table must load, got %v", err)
	defer destroy_biome_table(biomes)

	b := biomes.biomes[1]
	set := make_tile_set(biome_tile_count(biomes))
	defer destroy_tile_set(set)

	gold, _ := find_material_index(materials, "Gold")
	for k in 0 ..< wang_set_size(b) {
		tile := b.tile_base + Tile_Id(k)
		tile_fill(set, tile, Cell(k % len(materials.materials)))
		tile_set_cell(set, tile, TILE_SIZE / 2, TILE_SIZE / 2, Cell(gold))
	}

	written, failed, save_ok := save_tile_set(set, biomes, 1, materials)
	testing.expectf(t, save_ok, "the set must save, and %s did not", failed)
	testing.expect(t, written == WANG_SIGNATURES, "one file per tile")
	defer {
		for k in 0 ..< wang_set_size(b) {
			os.remove(biome_tile_path(biomes, 1, b.tile_base + Tile_Id(k)))
		}
	}

	testing.expect(t, os.exists("tile_trip.tmp_0000_0.png"), "the name carries the edge colors")
	testing.expect(t, os.exists("tile_trip.tmp_1111_0.png"))

	reloaded, result, _ := load_tile_set(biomes, materials, false)
	testing.expectf(t, result.err == .None, "the set must reload, got %v", result.err)
	defer destroy_tile_set(reloaded)

	for c, i in set.cells {
		testing.expectf(t, reloaded.cells[i] == c, "cell %d changed on the way back", i)
	}
}
