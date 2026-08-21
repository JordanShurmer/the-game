package game

import "core:testing"

Biome_Map :: struct {
	cells:  []Biome_Id,
	width:  i32,
	height: i32,
}

make_biome_map :: proc(width, height: i32, allocator := context.allocator) -> Biome_Map {
	cells := make([]Biome_Id, int(width) * int(height), allocator)
	for &c in cells do c = BIOME_EMPTY
	return Biome_Map{cells = cells, width = width, height = height}
}

destroy_biome_map :: proc(m: Biome_Map, allocator := context.allocator) {
	delete(m.cells, allocator)
}

biome_map_at :: proc(m: Biome_Map, px, py: i32) -> Biome_Id {
	if px < 0 || py < 0 || px >= m.width || py >= m.height do return BIOME_EMPTY
	return m.cells[int(py) * int(m.width) + int(px)]
}

biome_map_set :: proc(m: Biome_Map, px, py: i32, id: Biome_Id) {
	if px < 0 || py < 0 || px >= m.width || py >= m.height do return
	m.cells[int(py) * int(m.width) + int(px)] = id
}

biome_map_label_components :: proc(
	m: Biome_Map,
	labels: []i32,
	allocator := context.temp_allocator,
) -> (
	count: int,
) {
	assert(len(labels) == len(m.cells), "labels must match the map size")
	for &l in labels do l = -1

	stack := make([dynamic]i32, 0, len(m.cells), allocator)
	defer delete(stack)

	for start in 0 ..< len(m.cells) {
		if m.cells[start] == BIOME_EMPTY || labels[start] >= 0 do continue

		label := i32(count)
		count += 1

		labels[start] = label
		clear(&stack)
		append(&stack, i32(start))

		for len(stack) > 0 {
			idx := pop(&stack)
			x := idx % m.width
			y := idx / m.width

			push_neighbour :: proc(
				m: Biome_Map,
				labels: []i32,
				stack: ^[dynamic]i32,
				label: i32,
				nx, ny: i32,
			) {
				if nx < 0 || ny < 0 || nx >= m.width || ny >= m.height do return
				n := ny * m.width + nx
				if m.cells[n] == BIOME_EMPTY || labels[n] >= 0 do return
				labels[n] = label
				append(stack, n)
			}

			push_neighbour(m, labels, &stack, label, x - 1, y)
			push_neighbour(m, labels, &stack, label, x + 1, y)
			push_neighbour(m, labels, &stack, label, x, y - 1)
			push_neighbour(m, labels, &stack, label, x, y + 1)
		}
	}
	return count
}

biome_map_component_count :: proc(m: Biome_Map, allocator := context.temp_allocator) -> int {
	labels := make([]i32, len(m.cells), allocator)
	defer delete(labels, allocator)
	return biome_map_label_components(m, labels, allocator)
}

biome_map_is_connected :: proc(m: Biome_Map, allocator := context.temp_allocator) -> bool {
	return biome_map_component_count(m, allocator) <= 1
}

@(private = "file")
build_test_map :: proc(rows: []string, allocator := context.allocator) -> Biome_Map {
	height := i32(len(rows))
	width := i32(len(rows[0]))
	m := make_biome_map(width, height, allocator)
	for row, y in rows {
		for x in 0 ..< len(row) {
			if row[x] == '.' do continue
			biome_map_set(m, i32(x), i32(y), Biome_Id(row[x] - 'a'))
		}
	}
	return m
}

@(test)
test_biome_map_defaults_to_empty :: proc(t: ^testing.T) {
	m := make_biome_map(4, 3)
	defer destroy_biome_map(m)

	testing.expect(t, len(m.cells) == 12)
	for c in m.cells do testing.expect(t, c == BIOME_EMPTY)

	testing.expect(t, biome_map_at(m, -1, 0) == BIOME_EMPTY)
	testing.expect(t, biome_map_at(m, 0, -1) == BIOME_EMPTY)
	testing.expect(t, biome_map_at(m, 4, 0) == BIOME_EMPTY)
	testing.expect(t, biome_map_at(m, 0, 3) == BIOME_EMPTY)

	biome_map_set(m, 2, 1, 5)
	testing.expect(t, biome_map_at(m, 2, 1) == 5)
	biome_map_set(m, 9, 9, 7)
}

@(test)
test_biome_map_connectivity :: proc(t: ^testing.T) {
	Case :: struct {
		name:      string,
		rows:      []string,
		want:      int,
		connected: bool,
	}

	cases := []Case{
		{"empty map", []string{"...", "...", "..."}, 0, true},
		{"one pixel", []string{"...", ".a.", "..."}, 1, true},
		{"one blob", []string{"aa.", "aa.", "..."}, 1, true},
		{"mixed biomes still one blob", []string{"ab.", "cc.", "..."}, 1, true},
		{"two blobs", []string{"a.b", "a.b", "..."}, 2, false},
		{"diagonal touch does not join", []string{"a..", ".b.", "..."}, 2, false},
		{"L shape", []string{"a..", "a..", "aaa"}, 1, true},
		{"ring", []string{"aaa", "a.a", "aaa"}, 1, true},
		{"three blobs", []string{"a.b", "...", "c.."}, 3, false},
	}

	for c in cases {
		m := build_test_map(c.rows)
		defer destroy_biome_map(m)

		got := biome_map_component_count(m)
		testing.expectf(t, got == c.want, "%s: want %d components, got %d", c.name, c.want, got)
		testing.expectf(
			t,
			biome_map_is_connected(m) == c.connected,
			"%s: want connected=%v",
			c.name,
			c.connected,
		)
	}
}

@(test)
test_biome_map_labels_identify_components :: proc(t: ^testing.T) {
	m := build_test_map([]string{"a.b", "a.b", "..b"})
	defer destroy_biome_map(m)

	labels := make([]i32, len(m.cells))
	defer delete(labels)

	count := biome_map_label_components(m, labels)
	testing.expect(t, count == 2)

	testing.expect(t, labels[1] == -1)

	testing.expect(t, labels[0] == labels[3], "left column is one component")
	testing.expect(t, labels[2] == labels[5] && labels[5] == labels[8], "right column is one")
	testing.expect(t, labels[0] != labels[2], "the columns are different components")
}
