package game

import "core:os"
import "core:strings"
import "core:testing"
import rl "vendor:raylib"

/*
A tile on disk is a PNG painted in material colors.

The level format is an image, so any pixel editor is a tile editor and
the in-game editor writes the same file. This is the same trade the
biome map makes one level up: the map says which biome owns a region,
and a tile says what that biome is made of.

Air is color 0x00000000, so air reads and writes as a transparent
pixel with no special case. Every other pixel must match a material
color exactly. A near miss is a mistake, not a shade, so it stops the
load.
*/

Tile_Load_Error :: enum u8 {
	None,
	File_Unreadable,
	Wrong_Size,      // the image is not TILE_SIZE square
	Unmatched_Color, // a pixel color matches no material
}

/*
Where the problem is, so the author can find it.

For Unmatched_Color, x and y are the bad pixel and color is what it
holds. For Wrong_Size, x and y are the size the image turned out to
be. Nothing else needs a second struct.
*/
Tile_Load_Result :: struct {
	color: u32, // the unmatched color, 0xAARRGGBB
	x:     i32,
	y:     i32,
	err:   Tile_Load_Error,
}

/*
Read a tile into cells the caller owns.

The tile set allocates every tile in one block, so the loader writes
into a slice of that block instead of returning one of its own. This
is the same rule generation follows.
*/
load_tile_png :: proc(path: string, materials: Material_Table, dst: []Cell) -> Tile_Load_Result {
	assert(len(dst) == TILE_AREA, "a tile buffer is TILE_AREA cells")

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

	if img.width != TILE_SIZE || img.height != TILE_SIZE {
		return {err = .Wrong_Size, x = img.width, y = img.height}
	}

	// LoadImageColors normalises any source format to RGBA8.
	pixels := rl.LoadImageColors(img)
	defer rl.UnloadImageColors(pixels)

	for y in i32(0) ..< TILE_SIZE {
		for x in i32(0) ..< TILE_SIZE {
			argb := argb_from_rl(pixels[int(y) * TILE_SIZE + int(x)])
			idx, found := find_material_by_color(materials, argb)
			if !found {
				return {err = .Unmatched_Color, color = argb, x = x, y = y}
			}
			dst[int(y) * TILE_SIZE + int(x)] = Cell(idx)
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

	// The image borrows our buffer, so raylib must not free it.
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

/*
Read every tile the biome table names.

A tile with no file on disk starts as a flat block of the fill
material of the biome that owns it. A biome that gains a tile then
looks exactly as it did with a flat fill, and the author paints from
there instead of from an empty screen.

`create_missing` writes those new tiles out. Tests leave it off, so
they never touch the working tree.
*/
load_tile_set :: proc(
	biomes: Biome_Table,
	materials: Material_Table,
	create_missing: bool,
	allocator := context.allocator,
) -> (
	set: Tile_Set,
	result: Tile_Load_Result,
	bad_tile: Tile_Id, // which tile failed; TILE_NONE when none did
) {
	set = make_tile_set(biome_tile_count(biomes), allocator)

	// Which biome owns which tile, so a new tile knows what to fill
	// with. Tile ids are dense and come from the biome list in order.
	for b in biomes.biomes {
		if b.tile == TILE_NONE do continue

		path := biomes.tile_paths[b.tile]
		cells := tile_cells(set, b.tile)

		if os.exists(path) {
			r := load_tile_png(path, materials, cells)
			if r.err != .None {
				destroy_tile_set(set, allocator)
				return {}, r, b.tile
			}
			continue
		}

		tile_fill(set, b.tile, Cell(b.fill_0))
		if create_missing {
			if !save_tile_png(cells, materials, path) {
				destroy_tile_set(set, allocator)
				return {}, {err = .File_Unreadable}, b.tile
			}
		}
	}

	return set, {}, TILE_NONE
}

// ------------------------------------------------------------
// Tests
// ------------------------------------------------------------

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

	// Air is a transparent pixel, so the round trip proves alpha
	// survives the file as well as the colors do.
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
test_load_tile_set_reads_every_authored_tile :: proc(t: ^testing.T) {
	materials, biomes, ok := load_png_test_tables(t)
	if !ok do return
	defer destroy_biome_table(biomes)
	defer destroy_material_table(materials)

	// create_missing is off, so this test never writes to the repo.
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
	testing.expect(t, set.count > 0, "the shipped data must author at least one tile")

	// Every cell must name a real material, or the world would draw a
	// color that is not in the table.
	for c in set.cells {
		testing.expectf(t, int(c) < len(materials.materials), "cell holds unknown material %d", c)
	}
}

@(test)
test_load_tile_set_fills_a_missing_tile_with_the_biome_fill :: proc(t: ^testing.T) {
	materials, mat_ok := load_materials("data/materials.txt")
	testing.expect(t, mat_ok)
	defer destroy_material_table(materials)

	body := "[Map]\nbiome_off_map = A\n[A]\ncolor = 0xFF000001\nfill_0 = Rock\n" +
		"[B]\ncolor = 0xFF000002\nfill_0 = Sand\ngenerator = tile\ntile = tile_absent.tmp.png\n"
	path := "tile_set_missing.tmp.txt"
	testing.expect(t, os.write_entire_file(path, transmute([]byte)body) == nil)
	defer os.remove(path)

	biomes, err, _ := load_biomes(path, materials)
	testing.expectf(t, err == .None, "the table must load, got %v", err)
	defer destroy_biome_table(biomes)

	set, result, _ := load_tile_set(biomes, materials, false)
	testing.expectf(t, result.err == .None, "a missing tile is not an error, got %v", result.err)
	defer destroy_tile_set(set)

	sand, _ := find_material_index(materials, "Sand")
	testing.expect(t, set.count == 1)
	for c in tile_cells(set, 0) {
		testing.expect(t, c == Cell(sand), "a new tile starts as the fill of its biome")
	}
	testing.expect(t, !os.exists("tile_absent.tmp.png"), "create_missing off must write nothing")
}
