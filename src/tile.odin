package game

import "core:slice"
import "core:testing"

/*
Biome tiles.

A tile is a square block of authored cells. A biome that owns a tile
repeats that tile across the world instead of showing one flat
material.

This is the bottom rung of the ladder on purpose. There is no
herringbone lattice, no edge constraints, and no template: one tile
per biome, repeated. Phase 3 adds the lattice. The data does not
change shape when it does, because a tile stays a square block of
material ids whatever chooses it.

Every tile is the same size, and all tiles live in one allocation, so
the generator reads a tile the way it reads any other flat array.
*/

// Cells along one edge of a tile. It is a power of two, so the
// generator wraps a world coordinate with a mask instead of a
// division. The generator does that once per texel, so it counts.
TILE_SIZE :: 64
TILE_MASK :: TILE_SIZE - 1
TILE_AREA :: TILE_SIZE * TILE_SIZE

#assert(TILE_SIZE > 0 && (TILE_SIZE & TILE_MASK) == 0, "TILE_SIZE must be a power of two")

// A tile id indexes a Tile_Set. TILE_NONE marks a biome with no tile,
// which fills flat. The id fits the byte Biome left free.
Tile_Id :: u8

TILE_NONE :: Tile_Id(0xFF)
MAX_TILES :: 255 // 0xFF is reserved for TILE_NONE

/*
Every tile in the world, back to back.

`cells` is one block: tile `id` starts at `int(id) * TILE_AREA`. The
whole set is small (4 KB per tile), so it stays in cache while the
generator fills a screen.

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
// like this, so a biome that gains a tile looks the way it did with a
// flat fill until somebody paints it.
tile_fill :: proc(set: Tile_Set, id: Tile_Id, c: Cell) {
	slice.fill(tile_cells(set, id), c)
}

/*
The cell a tile shows at a world position.

The wrap is in world space, not region space, so the pattern runs
unbroken across two neighbouring regions of the same biome. It also
means a region never has to know where it starts.

A mask does the wrap. TILE_SIZE is a power of two, and two's
complement makes the mask give the floored remainder for negative
coordinates as well: `-1 & 63` is 63, the cell at the far edge of the
tile to the left. Plain `%` would fold the two sides of zero together,
the same trap floor_div avoids for regions.
*/
tile_sample :: proc(set: Tile_Set, id: Tile_Id, wx, wy: i32) -> Cell {
	x := wx & TILE_MASK
	y := wy & TILE_MASK
	return set.cells[int(id) * TILE_AREA + int(y) * TILE_SIZE + int(x)]
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

@(test)
test_tile_sample_wraps_across_the_origin :: proc(t: ^testing.T) {
	set := make_tile_set(1)
	defer destroy_tile_set(set)

	// Mark the four corners so a wrap that lands in the wrong place is
	// visible.
	tile_fill(set, 0, 0)
	tile_set_cell(set, 0, 0, 0, 1)
	tile_set_cell(set, 0, TILE_SIZE - 1, 0, 2)
	tile_set_cell(set, 0, 0, TILE_SIZE - 1, 3)
	tile_set_cell(set, 0, TILE_SIZE - 1, TILE_SIZE - 1, 4)

	testing.expect(t, tile_sample(set, 0, 0, 0) == 1)
	testing.expect(t, tile_sample(set, 0, TILE_SIZE, TILE_SIZE) == 1, "one tile over repeats")
	testing.expect(t, tile_sample(set, 0, -TILE_SIZE, -TILE_SIZE) == 1, "and so does one tile back")

	// The cell left of the origin is the last column, not the first.
	testing.expect(t, tile_sample(set, 0, -1, 0) == 2)
	testing.expect(t, tile_sample(set, 0, 0, -1) == 3)
	testing.expect(t, tile_sample(set, 0, -1, -1) == 4)

	// The pattern is unbroken: every position agrees with the position
	// one whole tile away, on both sides of the origin.
	for wy in i32(-TILE_SIZE - 3) ..< i32(TILE_SIZE + 3) {
		for wx in i32(-TILE_SIZE - 3) ..< i32(TILE_SIZE + 3) {
			a := tile_sample(set, 0, wx, wy)
			testing.expectf(
				t,
				a == tile_sample(set, 0, wx + TILE_SIZE, wy),
				"the tile must repeat across x at %d,%d",
				wx,
				wy,
			)
			testing.expectf(
				t,
				a == tile_sample(set, 0, wx, wy + TILE_SIZE),
				"the tile must repeat across y at %d,%d",
				wx,
				wy,
			)
		}
	}
}

@(test)
test_tile_sample_matches_the_plain_wrap :: proc(t: ^testing.T) {
	set := make_tile_set(1)
	defer destroy_tile_set(set)

	// A pattern with no symmetry, so a swapped axis shows up.
	for y in i32(0) ..< TILE_SIZE {
		for x in i32(0) ..< TILE_SIZE {
			tile_set_cell(set, 0, x, y, Cell((x * 7 + y * 13) & 0xFF))
		}
	}

	// floor_div gives the same wrap as the mask. It is the slow oracle.
	for wy in i32(-200) ..< i32(200) {
		for wx in i32(-200) ..< i32(200) {
			x := wx - floor_div(wx, TILE_SIZE) * TILE_SIZE
			y := wy - floor_div(wy, TILE_SIZE) * TILE_SIZE
			testing.expectf(
				t,
				tile_sample(set, 0, wx, wy) == tile_at(set, 0, x, y),
				"mask wrap must match floored wrap at %d,%d",
				wx,
				wy,
			)
		}
	}
}
