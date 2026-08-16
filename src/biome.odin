package game

import "core:fmt"
import "core:image"
import "core:image/png"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:testing"

/*
Biome map, biome table, and uniform generation (Slice 1).

A region is one biome-map pixel. Generation writes into a
caller-owned []Material_ID. There is no chunk store.
*/

Biome_Generator :: enum u8 {
	Uniform,
	// Wang and Noise arrive in later slices.
}

Biome :: struct {
	name:       string,       // owned
	color:      u32,          // key color in the map; also biome_salt later
	generator:  Biome_Generator,
	fill_0:     Material_ID,  // only fill used by uniform for now
}

Biome_Map :: struct {
	pixels:           []u32,  // 0xAARRGGBB, row-major
	width:            int,
	height:           int,
	origin_pixel:     [2]i32, // map pixel that is region (0, 0)
	cells_per_pixel:  i32,    // region size in world cells
	biome_off_map:    int,    // index into biomes
	biome_above:      int,    // index into biomes; -1 if none
	image_path:       string, // owned; for error messages / hot reload
}

World :: struct {
	materials: Material_Table,
	biomes:    []Biome,       // owned names
	map:       Biome_Map,
}

destroy_world :: proc(world: ^World, allocator := context.allocator) {
	destroy_material_table(world.materials, allocator)
	for b in world.biomes {
		delete(b.name, allocator)
	}
	delete(world.biomes, allocator)
	delete(world.map.pixels, allocator)
	delete(world.map.image_path, allocator)
	world^ = {}
}

// Floored division for world → region. Odin / truncates toward zero.
floor_div_i32 :: proc(a, b: i32) -> i32 {
	q := a / b
	r := a % b
	if (r != 0) && ((a < 0) != (b < 0)) {
		q -= 1
	}
	return q
}

region_of_world_cell :: proc(world: ^World, wx, wy: i32) -> (rx, ry: i32) {
	cpp := world.map.cells_per_pixel
	return floor_div_i32(wx, cpp), floor_div_i32(wy, cpp)
}

// Which biome owns this region coordinate.
biome_index_at_region :: proc(world: ^World, rx, ry: i32) -> int {
	m := world.map
	px := rx + m.origin_pixel.x
	py := ry + m.origin_pixel.y

	if py < 0 {
		if m.biome_above >= 0 {
			return m.biome_above
		}
		return m.biome_off_map
	}
	if px < 0 || py < 0 || int(px) >= m.width || int(py) >= m.height {
		return m.biome_off_map
	}
	color := m.pixels[int(py) * m.width + int(px)]
	for b, i in world.biomes {
		if b.color == color {
			return i
		}
	}
	// Unmatched colors are rejected at load time, so this is a safety net.
	return m.biome_off_map
}

// Fill dest with the uniform material of each overlapping region.
// dest must have at least w * h elements.
generate :: proc(
	world: ^World,
	dest: []Material_ID,
	w, h: int,
	world_origin: [2]i32,
	seed: u64, // unused in uniform; kept for signature stability
) {
	assert(len(dest) >= w * h)
	cpp := world.map.cells_per_pixel

	for y in 0 ..< h {
		wy := world_origin.y + i32(y)
		ry := floor_div_i32(wy, cpp)
		for x in 0 ..< w {
			wx := world_origin.x + i32(x)
			rx := floor_div_i32(wx, cpp)
			bi := biome_index_at_region(world, rx, ry)
			dest[y * w + x] = world.biomes[bi].fill_0
		}
	}
}
