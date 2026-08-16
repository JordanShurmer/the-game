package game

/*
Biome definition.

Fat struct by design. The generator reads every field here in one
loop, so they stay together in cache. Cold data (display name) lives
in a parallel array indexed by the same biome id, like Material_Table.

Phase 1 supports one generator: Uniform. It fills a whole region with
one material. Wang tiles and noise arrive in later phases.
*/

Biome_Generator :: enum u8 {
	Uniform,
}

// A biome id indexes Biome_Table.biomes. Ids are u8, so a map cell is
// one byte. BIOME_EMPTY marks a map pixel with no biome painted.
Biome_Id :: u8

BIOME_EMPTY :: Biome_Id(0xFF)
MAX_BIOMES  :: 255 // 0xFF is reserved for BIOME_EMPTY

// 8 bytes. Largest field first, so there is no interior padding.
// One trailing byte is free for the next phase.
Biome :: struct {
	key_color: u32,             // 0xAARRGGBB key in the biome map image
	fill_0:    u16,             // material id; index into Material_Table
	generator: Biome_Generator,
}

#assert(size_of(Biome) == 8)

/*
The biome table holds every biome plus the settings from the [Map]
section. Generation needs both, so they travel together.
*/
Biome_Table :: struct {
	biomes:          []Biome,
	names:           []string, // cold data, parallel to biomes
	map_image_path:  string,
	cells_per_pixel: i32,      // world cells along one edge of a region
	origin_pixel_x:  i32,      // map pixel that holds world cell (0,0)
	origin_pixel_y:  i32,
	off_map_biome:   Biome_Id, // biome used outside the map image
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
