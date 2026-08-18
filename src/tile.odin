package game

import "core:slice"
import "core:testing"

/*
Biome tiles.

A tile is a square block of authored cells. A biome that owns tiles
draws them across the world instead of showing one flat material.

A biome owns a whole set, not one tile. The world is cut into a
lattice of tile squares, and each square takes the tile of the set
that fits the edges around it. wang.odin decides which one that is.
This file only holds the cells and hands them out.

Every tile is the same size, and all tiles of every biome live in one
allocation, so the generator reads a tile the way it reads any other
flat array.
*/

// Cells along one edge of a tile. It is a power of two, so a world
// coordinate wraps into a tile with a mask instead of a division. The
// generator does that once per texel, so it counts.
TILE_SIZE :: 64
TILE_MASK :: TILE_SIZE - 1
TILE_AREA :: TILE_SIZE * TILE_SIZE

#assert(TILE_SIZE > 0 && (TILE_SIZE & TILE_MASK) == 0, "TILE_SIZE must be a power of two")

/*
A tile id indexes a Tile_Set. TILE_NONE marks a biome with no tiles,
which fills flat.

The id is two bytes now. A biome owns WANG_SIGNATURES tiles times its
variants, so a handful of tiled biomes passes what one byte holds.
*/
Tile_Id :: u16

TILE_NONE :: Tile_Id(0xFFFF)
MAX_TILES :: 4096 // far past what an author can draw, and 8 MB of cells

/*
Every tile in the world, back to back.

`cells` is one block: tile `id` starts at `int(id) * TILE_AREA`. One
tile is 4 KB and one complete set is 64 KB per variant, so a biome
set stays inside the second level cache while the generator fills a
screen from it.

The set holds no names or paths. Cold authoring data lives in
Biome_Table, next to the other strings the loader owns.
*/
Tile_Set :: struct {
	cells: []Cell, // count * TILE_AREA
	count: int,
}

make_tile_set :: proc(count: int, allocator := context.allocator) -> Tile_Set {
	assert(count <= MAX_TILES, "a world holds at most MAX_TILES tiles")
	return Tile_Set{cells = make([]Cell, count * TILE_AREA, allocator), count = count}
}

destroy_tile_set :: proc(set: Tile_Set, allocator := context.allocator) {
	delete(set.cells, allocator)
}

/*
The cells of one tile.

The editor paints into this slice and the PNG loader reads into it, so
neither needs to know how the set packs its tiles.
*/
tile_cells :: proc(set: Tile_Set, id: Tile_Id) -> []Cell {
	return set.cells[int(id) * TILE_AREA:][:TILE_AREA]
}

tile_at :: proc(set: Tile_Set, id: Tile_Id, x, y: i32) -> Cell {
	return set.cells[int(id) * TILE_AREA + int(y) * TILE_SIZE + int(x)]
}

// Writes outside the tile are dropped, so the editor needs no bounds
// test of its own.
tile_set_cell :: proc(set: Tile_Set, id: Tile_Id, x, y: i32, c: Cell) {
	if x < 0 || y < 0 || x >= TILE_SIZE || y >= TILE_SIZE do return
	set.cells[int(id) * TILE_AREA + int(y) * TILE_SIZE + int(x)] = c
}

// Paint a whole tile one material. A tile with no file on disk starts
// like this, so a biome that gains a set looks the way it did with a
// flat fill until somebody paints it.
tile_fill :: proc(set: Tile_Set, id: Tile_Id, c: Cell) {
	slice.fill(tile_cells(set, id), c)
}

/*
The lattice square a world coordinate falls in.

The lattice is in world space, not region space, so it runs unbroken
across two neighbouring regions of the same biome, and a region never
has to know where it starts.

floor_div, not a truncating divide: the square left of zero is -1, not
0, and folding the two sides of the origin together would put a seam
there that no edge color asked for.
*/
tile_slot :: proc(w: i32) -> i32 {
	return floor_div(w, TILE_SIZE)
}

/*
Where a world coordinate lands inside its tile.

A mask does the wrap. TILE_SIZE is a power of two, and two's
complement makes the mask give the floored remainder for negative
coordinates as well: `-1 & 63` is 63, the cell at the far edge of the
tile to the left.
*/
tile_offset :: proc(w: i32) -> i32 {
	return w & TILE_MASK
}

// ------------------------------------------------------------
// Tests
// ------------------------------------------------------------

@(test)
test_tile_set_gives_each_tile_its_own_block :: proc(t: ^testing.T) {
	set := make_tile_set(3)
	defer destroy_tile_set(set)

	testing.expect(t, len(set.cells) == 3 * TILE_AREA)
	testing.expect(t, set.count == 3)

	tile_fill(set, 0, 1)
	tile_fill(set, 1, 2)
	tile_fill(set, 2, 3)

	// A write to one tile must not reach the next one.
	tile_set_cell(set, 1, 5, 6, 42)
	testing.expect(t, tile_at(set, 1, 5, 6) == 42)
	testing.expect(t, tile_at(set, 0, 5, 6) == 1, "tile 0 is untouched")
	testing.expect(t, tile_at(set, 2, 5, 6) == 3, "tile 2 is untouched")

	testing.expect(t, len(tile_cells(set, 1)) == TILE_AREA)
	testing.expect(t, tile_cells(set, 1)[6 * TILE_SIZE + 5] == 42)

	// Writes outside the tile are dropped, not folded into a neighbour.
	tile_set_cell(set, 0, TILE_SIZE, 0, 99)
	tile_set_cell(set, 0, -1, 0, 99)
	for c in tile_cells(set, 0) do testing.expect(t, c == 1 || c == 42)
}

/*
The lattice must not fold the two sides of the origin together. The
square left of world cell 0 is square -1, and its last column is the
cell at world x -1.
*/
@(test)
test_tile_lattice_crosses_the_origin :: proc(t: ^testing.T) {
	testing.expect(t, tile_slot(0) == 0)
	testing.expect(t, tile_slot(TILE_SIZE - 1) == 0)
	testing.expect(t, tile_slot(TILE_SIZE) == 1)
	testing.expect(t, tile_slot(-1) == -1)
	testing.expect(t, tile_slot(-TILE_SIZE) == -1)
	testing.expect(t, tile_slot(-TILE_SIZE - 1) == -2)

	testing.expect(t, tile_offset(0) == 0)
	testing.expect(t, tile_offset(-1) == TILE_SIZE - 1)
	testing.expect(t, tile_offset(-TILE_SIZE) == 0)

	// The two together rebuild the coordinate they came from, on both
	// sides of the origin.
	for w in i32(-200) ..< i32(200) {
		testing.expectf(
			t,
			tile_slot(w) * TILE_SIZE + tile_offset(w) == w,
			"the lattice must account for every cell, and it lost %d",
			w,
		)
	}
}
