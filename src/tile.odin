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

// Cells along one edge of an authored tile. This is the size of the
// PNG on disk and the size the tile editor paints, and it does not
// change when the world scales.
TILE_SIZE :: 64
TILE_MASK :: TILE_SIZE - 1
TILE_AREA :: TILE_SIZE * TILE_SIZE

#assert(TILE_SIZE > 0 && (TILE_SIZE & TILE_MASK) == 0, "TILE_SIZE must be a power of two")

/*
World cells one authored cell covers, along each axis.

The tiles are drawn at a size a person can paint, and the world is
drawn at a size a wizard can walk through. Those are two different
questions, and this constant is the only place they meet: one painted
cell becomes a TILE_SCALE by TILE_SCALE block of world cells.

Everything the art says scales with it and nothing has to be redrawn.
The tunnel mouth in a seam band is TILE_SCALE times wider, so the
clear channel between two tiles is as well, which is what lets a body
of PLAYER_BODY_H through a set drawn for a smaller one.

It is a power of two for the same reason TILE_SIZE is: the generator
turns a world coordinate into an authored cell once per texel, and a
mask and a shift cost nothing where a division would show. A scale of
three would also make a region stop being a whole number of tiles,
because cells_per_pixel is 512, which leaves 1, 2, 4 and 8.

Four is what the reference asks for. Measured off a Noita mine, the
player stands about 7 percent of the screen high and the cave he
stands in is about five of him floor to ceiling. Our wizard is already
7 percent of the screen at zoom 4, so only the cave was wrong: at this
scale the channel between two tiles is 64 cells against a body of 13,
which is that same five. Eight would give the one huge cavern of a
promotional shot and put a single tile across a whole region.

What it costs, said plainly: the ground is drawn at a quarter of the
resolution of the wizard. One painted cell is one sample, so a wall of
rock steps in blocks of TILE_SCALE while the sprite beside it carries
detail in single cells, and a shot of a cave edge shows the stairs.
This scale buys size and cannot buy detail.

The rung that buys the detail back is a larger TILE_SIZE with the same
span: the same caves painted at 128 or 256 cells and drawn at a
smaller TILE_SCALE. It costs a reseed of every authored set, a tile
editor that works at that size, and the cache budget the set is sized
for above, which is why it is a rung and not this one.
*/
TILE_SCALE :: 4
TILE_SCALE_BITS :: 2

#assert(1 << TILE_SCALE_BITS == TILE_SCALE, "TILE_SCALE must be a power of two")

// World cells along one edge of a lattice square. This is the tile as
// the world holds it, and it is what a region has to be a whole
// number of.
TILE_SPAN :: TILE_SIZE * TILE_SCALE
TILE_SPAN_MASK :: TILE_SPAN - 1

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
	return floor_div(w, TILE_SPAN)
}

/*
Where a world coordinate lands inside its lattice square, in world
cells.

A mask does the wrap. TILE_SPAN is a power of two, and two's
complement makes the mask give the floored remainder for negative
coordinates as well: at TILE_SCALE 1, `-1 & 63` is 63, the cell at the
far edge of the tile to the left.
*/
tile_offset :: proc(w: i32) -> i32 {
	return w & TILE_SPAN_MASK
}

/*
The authored cell a world coordinate reads.

TILE_SCALE world cells in a row read one painted cell, so this is the
offset within the square divided by the scale. A shift does it,
because both are powers of two.

This is the proc the generator calls, and tile_offset is the proc that
answers where a border falls. Keeping the two apart is what stops a
lattice border being tested in painted cells, where TILE_SCALE world
cells would all look like the start of a tile.
*/
tile_cell :: proc(w: i32) -> i32 {
	return tile_offset(w) >> u32(TILE_SCALE_BITS)
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
	testing.expect(t, tile_slot(TILE_SPAN - 1) == 0)
	testing.expect(t, tile_slot(TILE_SPAN) == 1)
	testing.expect(t, tile_slot(-1) == -1)
	testing.expect(t, tile_slot(-TILE_SPAN) == -1)
	testing.expect(t, tile_slot(-TILE_SPAN - 1) == -2)

	testing.expect(t, tile_offset(0) == 0)
	testing.expect(t, tile_offset(-1) == TILE_SPAN - 1)
	testing.expect(t, tile_offset(-TILE_SPAN) == 0)

	// The two together rebuild the coordinate they came from, on both
	// sides of the origin.
	for w in i32(-200) ..< i32(200) {
		testing.expectf(
			t,
			tile_slot(w) * TILE_SPAN + tile_offset(w) == w,
			"the lattice must account for every cell, and it lost %d",
			w,
		)
	}
}

/*
The scale, from the side the generator reads it.

A run of TILE_SCALE world cells reads one painted cell, the square
holds every painted cell exactly once, and the count is right on both
sides of the origin. Off-by-one here is a world that samples the wrong
column of the art, which is invisible in a shot and visible as a seam.
*/
@(test)
test_a_painted_cell_covers_a_block_of_world_cells :: proc(t: ^testing.T) {
	testing.expect(t, tile_cell(0) == 0)
	testing.expect(t, tile_cell(TILE_SCALE - 1) == 0, "the first painted cell holds TILE_SCALE world cells")
	testing.expect(t, tile_cell(TILE_SCALE) == 1, "and the next world cell starts the next one")
	testing.expect(t, tile_cell(TILE_SPAN - 1) == TILE_SIZE - 1, "the last world cell of a square reads the last column")
	testing.expect(t, tile_cell(-1) == TILE_SIZE - 1, "the cell left of the origin is in the square to the left")

	// Every painted cell of a square is covered, by exactly TILE_SCALE
	// world cells, in order. Walk two whole squares either side of the
	// origin so a sign error cannot hide.
	counts: [TILE_SIZE]int
	for w in i32(-TILE_SPAN) ..< i32(TILE_SPAN) {
		c := tile_cell(w)
		testing.expectf(t, c >= 0 && c < TILE_SIZE, "world cell %d reads column %d, outside the tile", w, c)
		counts[c] += 1
	}
	for n, c in counts {
		testing.expectf(t, n == 2 * TILE_SCALE, "painted cell %d is read by %d world cells of the two squares", c, n)
	}
}
