package game

import "core:os"
import "core:strings"
import "core:testing"
import rl "vendor:raylib"

Biome_Map_Load_Error :: enum u8 {
	None,
	File_Unreadable,
	Unmatched_Color,
}

Biome_Map_Load_Result :: struct {
	color: u32,
	x:     i32,
	y:     i32,
	err:   Biome_Map_Load_Error,
}

load_biome_map_png :: proc(
	path: string,
	table: Biome_Table,
	allocator := context.allocator,
) -> (
	m: Biome_Map,
	result: Biome_Map_Load_Result,
) {
	if !os.exists(path) {
		return {}, {err = .File_Unreadable}
	}

	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	defer delete(cpath, context.temp_allocator)

	img := rl.LoadImage(cpath)
	if img.data == nil || img.width <= 0 || img.height <= 0 {
		return {}, {err = .File_Unreadable}
	}
	defer rl.UnloadImage(img)

	pixels := rl.LoadImageColors(img)
	defer rl.UnloadImageColors(pixels)

	m = make_biome_map(img.width, img.height, allocator)

	for y in 0 ..< img.height {
		for x in 0 ..< img.width {
			c := pixels[int(y) * int(img.width) + int(x)]
			if c.a == 0 do continue

			argb := argb_from_rl(c)
			id, found := find_biome_by_color(table, argb)
			if !found {
				destroy_biome_map(m, allocator)
				return {}, {err = .Unmatched_Color, color = argb, x = x, y = y}
			}
			biome_map_set(m, x, y, id)
		}
	}

	return m, {}
}

save_biome_map_png :: proc(m: Biome_Map, table: Biome_Table, path: string) -> bool {
	pixels := make([]rl.Color, len(m.cells), context.temp_allocator)
	defer delete(pixels, context.temp_allocator)

	for c, i in m.cells {
		if c == BIOME_EMPTY {
			pixels[i] = rl.Color{0, 0, 0, 0}
			continue
		}
		pixels[i] = rl_from_argb(table.biomes[c].key_color)
	}

	img := rl.Image {
		data    = raw_data(pixels),
		width   = m.width,
		height  = m.height,
		mipmaps = 1,
		format  = .UNCOMPRESSED_R8G8B8A8,
	}

	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	defer delete(cpath, context.temp_allocator)

	return bool(rl.ExportImage(img, cpath))
}

@(test)
test_biome_map_png_round_trip :: proc(t: ^testing.T) {
	materials, mat_ok := load_materials("data/materials.txt")
	testing.expect(t, mat_ok)
	defer destroy_material_table(materials)

	table, err, _ := load_biomes("data/biomes.txt", materials)
	testing.expect(t, err == .None)
	defer destroy_biome_table(table)

	m := make_biome_map(6, 4)
	defer destroy_biome_map(m)

	sky, _ := find_biome_index(table, "Sky")
	lake, _ := find_biome_index(table, "Lake")
	biome_map_set(m, 0, 0, Biome_Id(sky))
	biome_map_set(m, 1, 0, Biome_Id(sky))
	biome_map_set(m, 1, 1, Biome_Id(lake))
	biome_map_set(m, 5, 3, Biome_Id(lake))

	path := "biome_map_round_trip.tmp.png"
	defer os.remove(path)
	testing.expect(t, save_biome_map_png(m, table, path), "save must succeed")

	loaded, result := load_biome_map_png(path, table)
	defer destroy_biome_map(loaded)

	testing.expectf(t, result.err == .None, "load must succeed, got %v", result.err)
	testing.expect(t, loaded.width == m.width && loaded.height == m.height)
	for c, i in m.cells {
		testing.expectf(t, loaded.cells[i] == c, "pixel %d: want %v, got %v", i, c, loaded.cells[i])
	}
}

@(test)
test_biome_map_png_unmatched_color_is_an_error :: proc(t: ^testing.T) {
	materials, mat_ok := load_materials("data/materials.txt")
	testing.expect(t, mat_ok)
	defer destroy_material_table(materials)

	table, err, _ := load_biomes("data/biomes.txt", materials)
	testing.expect(t, err == .None)
	defer destroy_biome_table(table)

	pixels := []rl.Color{{0, 0, 0, 0}, {1, 2, 3, 255}}
	img := rl.Image {
		data    = raw_data(pixels),
		width   = 2,
		height  = 1,
		mipmaps = 1,
		format  = .UNCOMPRESSED_R8G8B8A8,
	}
	path := "biome_map_bad_color.tmp.png"
	defer os.remove(path)
	testing.expect(t, bool(rl.ExportImage(img, strings.clone_to_cstring(path, context.temp_allocator))))

	_, result := load_biome_map_png(path, table)
	testing.expect(t, result.err == .Unmatched_Color, "unknown colors are a hard error")
	testing.expect(t, result.color == 0xFF010203, "the report names the bad color")
	testing.expect(t, result.x == 1 && result.y == 0, "the report names the bad pixel")
}

@(test)
test_biome_map_png_missing_file_is_an_error :: proc(t: ^testing.T) {
	materials, mat_ok := load_materials("data/materials.txt")
	testing.expect(t, mat_ok)
	defer destroy_material_table(materials)

	table, err, _ := load_biomes("data/biomes.txt", materials)
	testing.expect(t, err == .None)
	defer destroy_biome_table(table)

	_, result := load_biome_map_png("data/no_such_map.png", table)
	testing.expect(t, result.err == .File_Unreadable)
}
