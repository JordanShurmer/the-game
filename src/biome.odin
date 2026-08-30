package game

import "core:fmt"

Biome_Generator :: enum u8 {
	Uniform,
	Wang,
	Image,
}

// How many pictures one image biome may own. A picture is a whole
// region, so the count is bounded by memory and not by a lattice: the
// homelands are twelve.
IMAGE_MAX_VARIANTS :: 16

Biome_Id :: u8

BIOME_EMPTY :: Biome_Id(0xFF)
MAX_BIOMES  :: 255

Biome :: struct {
	key_color: u32,
	fill_0:    u16,
	tile_base: Tile_Id,

	// A biome may be a light. `light` is the material it throws, and
	// how bright that is is the luminosity of that material, exactly as
	// it is for the orb and the crystals -- see docs/lighting.md,
	// "Every light is a material". The sky throws Daylight. Air is
	// material 0 and its luminosity is 0, so a biome that names nothing
	// throws nothing and needs no sentinel.
	light:     u16,

	variants:  u8,
	generator: Biome_Generator,
}

#assert(size_of(Biome) == 12)

Biome_Table :: struct {
	biomes:          []Biome,
	names:           []string,
	tile_prefixes:   []string,
	image_paths:     []string,
	map_image_path:  string,
	cells_per_pixel: i32,
	origin_pixel_x:  i32,
	origin_pixel_y:  i32,
	world_seed:      u64,
	off_map_biome:   Biome_Id,

	// Where the wizard starts: the nth region of this biome, counted
	// west to east along the row it lies on, one based. BIOME_EMPTY
	// leaves the search to look for a cave mouth near the origin.
	spawn_biome:     Biome_Id,
	spawn_region:    i32,

	// The other world, and the seed that opens it. See
	// src/laboratory.odin: everything above is the map one seed lays
	// out another way, and this is the map another seed opens instead.
	laboratory:      Laboratory,
}

biome_tile_count :: proc(table: Biome_Table) -> int {
	total := 0
	for b in table.biomes do total += wang_set_size(b)
	return total
}

// An image biome names a prefix, not a file, exactly as a wang biome
// does: its pictures are <prefix>_<variant>.png. A biome with one
// picture is the ordinary case and its file is <prefix>_0.png.
biome_image_path :: proc(table: Biome_Table, biome: Biome_Id, variant: int) -> string {
	return image_path(table.image_paths[biome], variant)
}

image_path :: proc(prefix: string, variant: int) -> string {
	return fmt.tprintf("%s_%d.png", prefix, variant)
}

biome_tile_path :: proc(table: Biome_Table, biome: Biome_Id, tile: Tile_Id) -> string {
	b := table.biomes[biome]
	sig := wang_signature_of(b, tile)
	return wang_tile_path(
		table.tile_prefixes[biome],
		sig,
		wang_variant_of(b, tile),
	)
}

find_biome_index :: proc(table: Biome_Table, name: string) -> (idx: int, found: bool) {
	for n, i in table.names {
		if n == name do return i, true
	}
	return -1, false
}

find_biome_by_color :: proc(table: Biome_Table, key_color: u32) -> (id: Biome_Id, found: bool) {
	for b, i in table.biomes {
		if b.key_color == key_color do return Biome_Id(i), true
	}
	return BIOME_EMPTY, false
}

biome_of_tile :: proc(table: Biome_Table, tile: Tile_Id) -> (id: Biome_Id, found: bool) {
	for b, i in table.biomes {
		if b.tile_base == TILE_NONE do continue
		if int(tile) >= int(b.tile_base) && int(tile) < int(b.tile_base) + wang_set_size(b) {
			return Biome_Id(i), true
		}
	}
	return BIOME_EMPTY, false
}
