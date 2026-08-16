package game

import "core:fmt"
import "core:os"
import "core:testing"

// ------------------------------------------------------------
// Tests
// ------------------------------------------------------------

@(test)
test_floor_div :: proc(t: ^testing.T) {
	testing.expect(t, floor_div_i32(5, 2) == 2)
	testing.expect(t, floor_div_i32(-1, 2) == -1)
	testing.expect(t, floor_div_i32(-2, 2) == -1)
	testing.expect(t, floor_div_i32(-3, 2) == -2)
	testing.expect(t, floor_div_i32(0, 64) == 0)
	testing.expect(t, floor_div_i32(-1, 64) == -1)
	testing.expect(t, floor_div_i32(-64, 64) == -1)
	testing.expect(t, floor_div_i32(-65, 64) == -2)
}

@(test)
test_load_world_and_uniform_generate :: proc(t: ^testing.T) {
	world, err, ok := load_world("data/materials.txt", "data/biomes.txt")
	defer destroy_world(&world)
	if !ok {
		testing.expect(t, false, format_config_error(err))
		return
	}

	testing.expect(t, len(world.biomes) == 2)
	testing.expect(t, world.map.width == 1)
	testing.expect(t, world.map.height == 1)
	testing.expect(t, world.map.cells_per_pixel == 64)

	rock_id, found := find_material_id(world.materials, "Rock")
	testing.expect(t, found)

	w, h := 32, 32
	dest := make([]Material_ID, w * h)
	defer delete(dest)

	generate(&world, dest, w, h, {0, 0}, 12345)

	for cell in dest {
		testing.expect(t, cell == rock_id)
	}

	// Determinism: same inputs → identical buffer.
	dest2 := make([]Material_ID, w * h)
	defer delete(dest2)
	generate(&world, dest2, w, h, {0, 0}, 12345)
	for i in 0 ..< w * h {
		testing.expect(t, dest[i] == dest2[i])
	}
}

@(test)
test_off_map_uses_biome_off_map :: proc(t: ^testing.T) {
	world, err, ok := load_world("data/materials.txt", "data/biomes.txt")
	defer destroy_world(&world)
	if !ok {
		testing.expect(t, false, format_config_error(err))
		return
	}

	// Region far outside the 1x1 map.
	bi := biome_index_at_region(&world, 100, 100)
	testing.expect(t, world.biomes[bi].name == "Deep_Rock")
}

@(test)
test_write_preview_ppm :: proc(t: ^testing.T) {
	world, err, ok := load_world("data/materials.txt", "data/biomes.txt")
	defer destroy_world(&world)
	if !ok {
		testing.expect(t, false, format_config_error(err))
		return
	}

	w, h := 64, 64
	dest := make([]Material_ID, w * h)
	defer delete(dest)
	generate(&world, dest, w, h, {0, 0}, 1)

	// Write a simple PPM so the vertical path is visible without raylib.
	f, ferr := os.open("preview.ppm", os.O_WRONLY | os.O_CREATE | os.O_TRUNC, 0o644)
	if ferr != os.ERROR_NONE {
		testing.expect(t, false, "could not write preview.ppm")
		return
	}
	defer os.close(f)

	hdr := fmt.tprintf("P3\n%d %d\n255\n", w, h)
	os.write_string(f, hdr)
	for y in 0 ..< h {
		for x in 0 ..< w {
			id := dest[y * w + x]
			c := world.materials.materials[id].color
			r := (c >> 16) & 0xff
			g := (c >> 8) & 0xff
			b := c & 0xff
			os.write_string(f, fmt.tprintf("%d %d %d ", r, g, b))
		}
		os.write_string(f, "\n")
	}
	testing.expect(t, true)
}
