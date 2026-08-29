package game

import "core:slice"
import testing "check"

TILE_SIZE :: 512
TILE_MASK :: TILE_SIZE - 1
TILE_AREA :: TILE_SIZE * TILE_SIZE

#assert(TILE_SIZE > 0 && (TILE_SIZE & TILE_MASK) == 0, "TILE_SIZE must be a power of two")

Tile_Id :: u16

TILE_NONE :: Tile_Id(0xFFFF)
MAX_TILES :: 256

// A phantom painted in a tile. A phantom is a light and not matter --
// the cell grid never holds one -- so a cell of one in a tile file is
// a mark, not a cell: it says a light lives here. The loader lifts
// every mark out of the cells (leaving Air) and keeps it beside the
// set, and the fireflies gather over the marks; see docs/water.md.
// Saving a tile stamps its marks back into the file, so an editor
// save cannot lose them.
Tile_Mark :: struct {
	tile:     Tile_Id,
	x, y:     u16,
	material: u16,
}

#assert(size_of(Tile_Mark) == 8)

Tile_Set :: struct {
	cells: []Cell,
	marks: [dynamic]Tile_Mark,
}

make_tile_set :: proc(count: int, allocator := context.allocator) -> Tile_Set {
	assert(count <= MAX_TILES, "a world holds at most MAX_TILES tiles")
	return Tile_Set{
		cells = make([]Cell, count * TILE_AREA, allocator),
		marks = make([dynamic]Tile_Mark, allocator),
	}
}

destroy_tile_set :: proc(set: Tile_Set, allocator := context.allocator) {
	delete(set.cells, allocator)
	delete(set.marks)
}

tile_cells :: proc(set: Tile_Set, id: Tile_Id) -> []Cell {
	return set.cells[int(id) * TILE_AREA:][:TILE_AREA]
}

tile_at :: proc(set: Tile_Set, id: Tile_Id, x, y: i32) -> Cell {
	return set.cells[int(id) * TILE_AREA + int(y) * TILE_SIZE + int(x)]
}

tile_set_cell :: proc(set: Tile_Set, id: Tile_Id, x, y: i32, c: Cell) {
	if x < 0 || y < 0 || x >= TILE_SIZE || y >= TILE_SIZE do return
	set.cells[int(id) * TILE_AREA + int(y) * TILE_SIZE + int(x)] = c
}

tile_fill :: proc(set: Tile_Set, id: Tile_Id, c: Cell) {
	slice.fill(tile_cells(set, id), c)
}

tile_slot :: proc(w: i32) -> i32 {
	return floor_div(w, TILE_SIZE)
}

tile_offset :: proc(w: i32) -> i32 {
	return w & TILE_MASK
}

@(test)
test_tile_set_gives_each_tile_its_own_block :: proc(t: ^testing.T) {
	set := make_tile_set(3)
	defer destroy_tile_set(set)

	testing.expect(t, len(set.cells) == 3 * TILE_AREA)

	tile_fill(set, 0, 1)
	tile_fill(set, 1, 2)
	tile_fill(set, 2, 3)

	tile_set_cell(set, 1, 5, 6, 42)
	testing.expect(t, tile_at(set, 1, 5, 6) == 42)
	testing.expect(t, tile_at(set, 0, 5, 6) == 1, "tile 0 is untouched")
	testing.expect(t, tile_at(set, 2, 5, 6) == 3, "tile 2 is untouched")

	testing.expect(t, len(tile_cells(set, 1)) == TILE_AREA)
	testing.expect(t, tile_cells(set, 1)[6 * TILE_SIZE + 5] == 42)

	tile_set_cell(set, 0, TILE_SIZE, 0, 99)
	tile_set_cell(set, 0, -1, 0, 99)
	for c in tile_cells(set, 0) do testing.expect(t, c == 1 || c == 42)
}

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

	for w in i32(-200) ..< i32(200) {
		testing.expectf(
			t,
			tile_slot(w) * TILE_SIZE + tile_offset(w) == w,
			"the lattice must account for every cell, and it lost %d",
			w,
		)
	}
}
