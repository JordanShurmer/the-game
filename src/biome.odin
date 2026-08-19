package game

/*
Biome definition.

Fat struct by design. The generator reads every field here in one
loop, so they stay together in cache. Cold data (display name, tile
file prefix) lives in a parallel array indexed by the same biome id,
like Material_Table.

A biome fills its regions one of two ways. Uniform gives the whole
region one material. Wang draws a lattice of tiles from the set the
biome owns, picking each one so its edges match its neighbours.
*/

Biome_Generator :: enum u8 {
	Uniform, // the whole region is fill_0
	Wang,    // the region is a lattice of tiles from the biome's set
	Image,   // the region is one PNG, one pixel to one world cell
}

// A biome id indexes Biome_Table.biomes. Ids are u8, so a map cell is
// one byte. BIOME_EMPTY marks a map pixel with no biome painted.
Biome_Id :: u8

BIOME_EMPTY :: Biome_Id(0xFF)
MAX_BIOMES  :: 255 // 0xFF is reserved for BIOME_EMPTY

/*
12 bytes, largest field first, so the only padding is the two bytes
the trailing pair of small fields leaves.

`tile_base` is the first tile of the set this biome owns, or
TILE_NONE. The set runs from there for WANG_SIGNATURES * variants
tiles, in signature order, so the generator finds a tile by arithmetic
and never by search. An image biome owns no tile set, so tile_base
stays TILE_NONE for it too: every place in the codebase that reads
`tile_base == TILE_NONE` to mean "no Wang set here" stays right
without change.

`variants` does two jobs, because an image biome has no variants to
count and the byte would otherwise sit idle. For a Wang biome it is
the tile count per signature, as the name says. For an image biome it
is instead the index of this biome's picture in World.images: the
loader hands out these indexes in file order, the same way it hands
out tile_base for a Wang set, so the generator finds the picture by
one array index and never by search.
*/
Biome :: struct {
	key_color: u32,             // 0xAARRGGBB key in the biome map image
	fill_0:    u16,             // material id; index into Material_Table
	tile_base: Tile_Id,         // first tile of the set, or TILE_NONE
	variants:  u8,              // Wang: tiles per signature. Image: index into World.images.
	generator: Biome_Generator,
}

#assert(size_of(Biome) == 12)

/*
The biome table holds every biome plus the settings from the [Map]
section. Generation needs both, so they travel together.

The table owns every string the author wrote, including the prefix
each tile set loads from and saves to. Tile pixels do not live here:
they live in a Tile_Set, which holds nothing but cells.
*/
Biome_Table :: struct {
	biomes:          []Biome,
	names:           []string, // cold data, parallel to biomes
	tile_prefixes:   []string, // cold data, parallel to biomes; "" for a flat biome
	image_paths:     []string, // cold data, parallel to biomes; "" for a biome with no image
	map_image_path:  string,
	cells_per_pixel: i32,      // world cells along one edge of a region
	origin_pixel_x:  i32,      // map pixel that holds world cell (0,0)
	origin_pixel_y:  i32,
	world_seed:      u64,      // seeds the tile lattice
	off_map_biome:   Biome_Id, // biome used outside the map image
}

// How many tiles the whole table asks for. The ids the loader hands
// out are dense, so this is also one past the largest id.
biome_tile_count :: proc(table: Biome_Table) -> int {
	total := 0
	for b in table.biomes do total += wang_set_size(b)
	return total
}

/*
The file one tile of a set lives in.

The name carries the constraint: the four digits are the edge colors
of the tile, north east south west, and the last number is which
variant of them it is. An author who opens data/tiles in a pixel
editor can see at a glance which files have to agree along which side.

The string comes from the temporary allocator, because every caller
uses it and drops it inside one frame or one tool call.
*/
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

// Which biome owns a tile. The sets are laid out one after another in
// biome order, so a short scan finds the owner.
biome_of_tile :: proc(table: Biome_Table, tile: Tile_Id) -> (id: Biome_Id, found: bool) {
	for b, i in table.biomes {
		if b.tile_base == TILE_NONE do continue
		if int(tile) >= int(b.tile_base) && int(tile) < int(b.tile_base) + wang_set_size(b) {
			return Biome_Id(i), true
		}
	}
	return BIOME_EMPTY, false
}
