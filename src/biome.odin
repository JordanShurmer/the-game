package game

Biome_Generator :: enum u8 {
	Uniform,
	Wang,
	Image,
}

Biome_Id :: u8

BIOME_EMPTY :: Biome_Id(0xFF)
MAX_BIOMES  :: 255

Biome :: struct {
	key_color: u32,
	fill_0:    u16,
	tile_base: Tile_Id,
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
}

biome_tile_count :: proc(table: Biome_Table) -> int {
	total := 0
	for b in table.biomes do total += wang_set_size(b)
	return total
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
