package game

import "core:math"
import "core:mem"
import "core:slice"
import "core:testing"

SANDBOX_MAX_WIDTH  :: 2048
SANDBOX_MAX_HEIGHT :: 2048

SANDBOX_CHUNK :: 64

EXPLODE_MIN_RAYS      :: 24
EXPLODE_RAYS_PER_CELL :: 6

CUT_SPRAY_CHANCE :: 40 // out of 255

CUT_SPRAY_NEAR :: 10

CUT_SPRAY_ACROSS :: 2

MATERIAL_AIR :: Cell(0)

Sandbox_Rect :: struct {
	min_x, min_y, max_x, max_y: i32,
}

SANDBOX_RECT_EMPTY :: Sandbox_Rect{1 << 30, 1 << 30, -1, -1}

Sandbox :: struct {
	cells:    []Cell,
	lifetime: []i16,
	moved:    []bool,
	width:    i32,
	height:   i32,

	origin_x: i32,
	origin_y: i32,

	tick:     u64,
	seed:     u64,

	dirty:      []Sandbox_Rect,
	next_dirty: []Sandbox_Rect,
	chunks_x:   i32,
	chunks_y:   i32,

	rows: Sandbox_Rows,
}

Sandbox_Rows :: struct {
	above: []u16,
	here:  []u16,
	below: []u16,
	kind:  []Cell_Kind,
	dx:    []i16,
	dy:    []i16,
}

sandbox_make :: proc(width, height: i32, seed: u64, allocator := context.allocator) -> (sb: Sandbox, ok: bool) {
	if width <= 0 || height <= 0 do return {}, false
	if width > SANDBOX_MAX_WIDTH || height > SANDBOX_MAX_HEIGHT do return {}, false

	count := int(width) * int(height)
	sb.cells = make([]Cell, count, allocator)
	sb.lifetime = make([]i16, count, allocator)
	sb.moved = make([]bool, count, allocator)
	sb.width = width
	sb.height = height
	sb.seed = seed

	sb.chunks_x = (width + SANDBOX_CHUNK - 1) / SANDBOX_CHUNK
	sb.chunks_y = (height + SANDBOX_CHUNK - 1) / SANDBOX_CHUNK
	chunk_count := int(sb.chunks_x) * int(sb.chunks_y)
	sb.dirty = make([]Sandbox_Rect, chunk_count, allocator)
	sb.next_dirty = make([]Sandbox_Rect, chunk_count, allocator)
	for &r in sb.dirty do r = SANDBOX_RECT_EMPTY
	for &r in sb.next_dirty do r = SANDBOX_RECT_EMPTY

	sb.rows.above = make([]u16, width + 2, allocator)
	sb.rows.here  = make([]u16, width + 2, allocator)
	sb.rows.below = make([]u16, width + 2, allocator)
	sb.rows.kind  = make([]Cell_Kind, width + 2, allocator)
	sb.rows.dx    = make([]i16, width, allocator)
	sb.rows.dy    = make([]i16, width, allocator)
	sb.rows.above[0], sb.rows.above[width + 1] = CELL_WALL, CELL_WALL
	sb.rows.here[0], sb.rows.here[width + 1] = CELL_WALL, CELL_WALL
	sb.rows.below[0], sb.rows.below[width + 1] = CELL_WALL, CELL_WALL

	return sb, true
}

sandbox_destroy :: proc(sb: ^Sandbox, allocator := context.allocator) {
	delete(sb.cells, allocator)
	delete(sb.lifetime, allocator)
	delete(sb.moved, allocator)
	delete(sb.dirty, allocator)
	delete(sb.next_dirty, allocator)
	delete(sb.rows.above, allocator)
	delete(sb.rows.here, allocator)
	delete(sb.rows.below, allocator)
	delete(sb.rows.kind, allocator)
	delete(sb.rows.dx, allocator)
	delete(sb.rows.dy, allocator)
	sb^ = {}
}

sandbox_in_bounds :: #force_inline proc(sb: ^Sandbox, x, y: i32) -> bool {
	return x >= 0 && y >= 0 && x < sb.width && y < sb.height
}

sandbox_index :: #force_inline proc(sb: ^Sandbox, x, y: i32) -> int {
	return int(y) * int(sb.width) + int(x)
}

sandbox_cell :: proc(sb: ^Sandbox, x, y: i32) -> Cell {
	if !sandbox_in_bounds(sb, x, y) do return MATERIAL_AIR
	return sb.cells[sandbox_index(sb, x, y)]
}

sandbox_fill_from_world :: proc(sb: ^Sandbox, world: World, origin_x, origin_y: i32) {
	view := World_View {
		x    = origin_x,
		y    = origin_y,
		w    = sb.width,
		h    = sb.height,
		step = 1,
	}
	generate(world, view, sb.cells)

	sb.origin_x = origin_x
	sb.origin_y = origin_y

	for c, i in sb.cells {
		sb.lifetime[i] = material_start_life(world.materials, c)
	}
	mem.zero_slice(sb.moved)

	sandbox_mark_all(sb)
}

sandbox_mark_all :: proc(sb: ^Sandbox) {
	for cy in i32(0) ..< sb.chunks_y {
		y0 := cy * SANDBOX_CHUNK
		y1 := min(y0+SANDBOX_CHUNK-1, sb.height-1)
		for cx in i32(0) ..< sb.chunks_x {
			x0 := cx * SANDBOX_CHUNK
			x1 := min(x0+SANDBOX_CHUNK-1, sb.width-1)
			r := Sandbox_Rect{x0, y0, x1, y1}
			ci := int(cy*sb.chunks_x + cx)
			sb.dirty[ci] = r
			sb.next_dirty[ci] = r
		}
	}
}

sandbox_mark :: proc(sb: ^Sandbox, x, y: i32) {
	lo_x := max(x-1, 0)
	hi_x := min(x+1, sb.width-1)
	lo_y := max(y-1, 0)
	hi_y := min(y+1, sb.height-1)

	cx0 := lo_x / SANDBOX_CHUNK
	cx1 := hi_x / SANDBOX_CHUNK
	cy0 := lo_y / SANDBOX_CHUNK
	cy1 := hi_y / SANDBOX_CHUNK

	for cy in cy0 ..= cy1 {
		chunk_y0 := cy * SANDBOX_CHUNK
		chunk_y1 := min(chunk_y0+SANDBOX_CHUNK-1, sb.height-1)
		cell_lo_y := max(lo_y, chunk_y0)
		cell_hi_y := min(hi_y, chunk_y1)

		for cx in cx0 ..= cx1 {
			chunk_x0 := cx * SANDBOX_CHUNK
			chunk_x1 := min(chunk_x0+SANDBOX_CHUNK-1, sb.width-1)
			cell_lo_x := max(lo_x, chunk_x0)
			cell_hi_x := min(hi_x, chunk_x1)

			ci := int(cy*sb.chunks_x + cx)
			r := &sb.next_dirty[ci]
			r.min_x = min(r.min_x, cell_lo_x)
			r.min_y = min(r.min_y, cell_lo_y)
			r.max_x = max(r.max_x, cell_hi_x)
			r.max_y = max(r.max_y, cell_hi_y)
		}
	}
}

sandbox_side_bit :: #force_inline proc "contextless" (sb: ^Sandbox, x, y: i32) -> u16 {
	h := u16(x) * 0x2545 + u16(y) * 0x9E3B + u16(sb.tick) * 0x85EB + sandbox_seed16(sb.seed)
	h ~= h >> 7
	h *= 0x2C1B
	return h >> 15
}

sandbox_seed16 :: #force_inline proc "contextless" (seed: u64) -> u16 {
	return u16(seed) ~ u16(seed >> 16) ~ u16(seed >> 32) ~ u16(seed >> 48)
}

Sandbox_Roll :: enum u32 {
	React_Side,
	React_Roll,
	Fire,
	Cut_Spray,
}

sandbox_chance :: proc "contextless" (sb: ^Sandbox, x, y: i32, roll: Sandbox_Roll, index: u32 = 0) -> u32 {
	h := u64(u32(x)) * 0x9E3779B97F4A7C15
	h ~= u64(u32(y)) * 0xC2B2AE3D27D4EB4F
	h ~= sb.tick * 0x165667B19E3779F9
	h ~= sb.seed
	h += u64(u32(roll)) * 256 + u64(index)
	h ~= h >> 33
	h *= 0xFF51AFD7ED558CCD
	h ~= h >> 29
	return u32(h)
}

sandbox_checksum :: proc(sb: ^Sandbox) -> u64 {
	FNV_OFFSET :: 0xcbf29ce484222325
	FNV_PRIME  :: 0x100000001b3

	hash: u64 = FNV_OFFSET
	for b in sb.cells {
		hash ~= u64(b)
		hash *= FNV_PRIME
	}
	for b in slice.to_bytes(sb.lifetime) {
		hash ~= u64(b)
		hash *= FNV_PRIME
	}

	tail := [5]u64 {
		sb.tick,
		u64(sb.width),
		u64(sb.height),
		u64(u32(sb.origin_x)),
		u64(u32(sb.origin_y)),
	}
	for v in tail {
		hash ~= v
		hash *= FNV_PRIME
	}
	return hash
}

material_start_life :: proc(table: Material_Table, material: Cell) -> i16 {
	if int(material) >= len(table.materials) do return -1
	life := table.materials[material].lifetime
	if life <= 0 do return -1
	return life > 32767 ? 32767 : i16(life)
}

sandbox_put :: #force_inline proc(sb: ^Sandbox, table: Material_Table, index: int, material: Cell) {
	sb.cells[index] = material
	sb.lifetime[index] = material_start_life(table, material)
	sandbox_mark(sb, i32(index)%sb.width, i32(index)/sb.width)
}

sandbox_paint :: proc(sb: ^Sandbox, table: Material_Table, cx, cy: i32, radius: i32, material: Cell) -> (changed: int) {
	if int(material) >= len(table.materials) do return 0

	r := radius < 0 ? 0 : radius
	r2 := r * r
	life := material_start_life(table, material)

	for y := max(cy-r, 0); y <= min(cy+r, sb.height-1); y += 1 {
		for x := max(cx-r, 0); x <= min(cx+r, sb.width-1); x += 1 {
			dx := x - cx
			dy := y - cy
			if dx*dx + dy*dy > r2 do continue

			i := sandbox_index(sb, x, y)
			if sb.cells[i] == material && sb.lifetime[i] == life do continue
			sb.cells[i] = material
			sb.lifetime[i] = life
			sandbox_mark(sb, x, y)
			changed += 1
		}
	}
	return changed
}

sandbox_ignite_cell :: proc(sb: ^Sandbox, table: Material_Table, x, y: i32) {
	index := sandbox_index(sb, x, y)
	material := sb.cells[index]
	m := table.materials[material]

	if m.explosive > 0 {
		sandbox_put(sb, table, index, MATERIAL_AIR)
		sb.moved[index] = true
		sandbox_explode(sb, table, x, y, i32(m.explosive), m.explosive)
		return
	}

	sandbox_put(sb, table, index, Cell(table.burns_to[material]))
	sb.moved[index] = true
}

sandbox_ignite :: proc(sb: ^Sandbox, table: Material_Table, cx, cy: i32, radius: i32) -> (changed: int) {
	r := radius < 0 ? 0 : radius
	r2 := r * r

	for y := max(cy-r, 0); y <= min(cy+r, sb.height-1); y += 1 {
		for x := max(cx-r, 0); x <= min(cx+r, sb.width-1); x += 1 {
			dx := x - cx
			dy := y - cy
			if dx*dx + dy*dy > r2 do continue

			i := sandbox_index(sb, x, y)
			material := sb.cells[i]
			if material == MATERIAL_AIR do continue
			if table.materials[material].flammability == 0 do continue

			sandbox_ignite_cell(sb, table, x, y)
			changed += 1
		}
	}
	return changed
}

sandbox_spread_fire :: proc(sb: ^Sandbox, table: Material_Table, x, y: i32) -> (fuel_nearby: bool) {
	offsets := [8][2]i32 {
		{1, 0}, {-1, 0}, {0, 1}, {0, -1},
		{1, 1}, {1, -1}, {-1, 1}, {-1, -1},
	}

	for o, k in offsets {
		nx := x + o[0]
		ny := y + o[1]
		if !sandbox_in_bounds(sb, nx, ny) do continue

		i := sandbox_index(sb, nx, ny)
		material := sb.cells[i]
		if material == MATERIAL_AIR do continue

		flammability := table.materials[material].flammability
		if flammability == 0 do continue
		fuel_nearby = true

		if sandbox_chance(sb, x, y, .Fire, u32(k)) & 255 >= u32(flammability) * 8 do continue

		sandbox_ignite_cell(sb, table, nx, ny)
	}
	return fuel_nearby
}

sandbox_explode :: proc(sb: ^Sandbox, table: Material_Table, cx, cy: i32, radius: i32, power: u8) -> (broken: int) {
	r := radius < 0 ? 0 : radius
	if r == 0 || power == 0 do return 0

	rays := max(EXPLODE_MIN_RAYS, r*EXPLODE_RAYS_PER_CELL)
	inner_r := r / 3

	fire_cell := Cell(table.fire)

	for ray in 0 ..< rays {
		angle := f32(ray) / f32(rays) * 2 * math.PI
		dx := math.cos(angle)
		dy := math.sin(angle)

		energy := i32(power)

		for step in i32(1) ..= r {
			x := cx + i32(math.round(dx * f32(step)))
			y := cy + i32(math.round(dy * f32(step)))
			if !sandbox_in_bounds(sb, x, y) do break

			i := sandbox_index(sb, x, y)
			material := sb.cells[i]
			cost := i32(table.materials[material].hardness) + 1
			if energy < cost do break
			energy -= cost

			if material == MATERIAL_AIR || material == fire_cell do continue

			broken += 1
			target := step <= inner_r ? fire_cell : MATERIAL_AIR
			sandbox_put(sb, table, i, target)
			sb.moved[i] = true

			sandbox_crumble_neighbours(sb, table, x, y)
		}
	}
	return broken
}

sandbox_crumble_neighbours :: proc(sb: ^Sandbox, table: Material_Table, x, y: i32) {
	offsets := [4][2]i32{{1, 0}, {-1, 0}, {0, 1}, {0, -1}}
	for o in offsets {
		nx := x + o[0]
		ny := y + o[1]
		if !sandbox_in_bounds(sb, nx, ny) do continue

		ni := sandbox_index(sb, nx, ny)
		neighbour := sb.cells[ni]
		crumbled := Cell(table.crumbles_to[neighbour])
		if crumbled == neighbour do continue

		sandbox_put(sb, table, ni, crumbled)
		sb.moved[ni] = true
	}
}

sandbox_dig :: proc(sb: ^Sandbox, table: Material_Table, cx, cy: i32, radius: i32, power: u8) -> (removed: int) {
	r := radius < 0 ? 0 : radius
	r2 := r * r

	for y := max(cy-r, 0); y <= min(cy+r, sb.height-1); y += 1 {
		for x := max(cx-r, 0); x <= min(cx+r, sb.width-1); x += 1 {
			dx := x - cx
			dy := y - cy
			if dx*dx + dy*dy > r2 do continue

			i := sandbox_index(sb, x, y)
			material := sb.cells[i]
			if material == MATERIAL_AIR do continue
			if table.materials[material].hardness > power do continue

			sandbox_put(sb, table, i, MATERIAL_AIR)
			removed += 1
		}
	}
	return removed
}

sandbox_cut :: proc(
	sb: ^Sandbox,
	table: Material_Table,
	cx, cy: i32,
	dx, dy: f32,
	range, half_width: i32,
	power: u8,
) -> (removed: int) {
	px, py := -dy, dx
	r2 := half_width * half_width

	reach := i32(0)
	for step in i32(1) ..= range {
		ax := cx + i32(math.round(dx * f32(step)))
		ay := cy + i32(math.round(dy * f32(step)))
		if !sandbox_in_bounds(sb, ax, ay) do break
		if table.materials[sb.cells[sandbox_index(sb, ax, ay)]].hardness > power do break
		reach = step
	}

	for step in i32(1) ..= reach {
		ax := cx + i32(math.round(dx * f32(step)))
		ay := cy + i32(math.round(dy * f32(step)))

		for y := max(ay-half_width, 0); y <= min(ay+half_width, sb.height-1); y += 1 {
			for x := max(ax-half_width, 0); x <= min(ax+half_width, sb.width-1); x += 1 {
				ox := x - ax
				oy := y - ay
				if ox*ox + oy*oy > r2 do continue

				if f32(x-cx)*dx + f32(y-cy)*dy > f32(reach) do continue

				i := sandbox_index(sb, x, y)
				material := sb.cells[i]
				if material == MATERIAL_AIR do continue
				if table.materials[material].hardness > power do continue

				sandbox_put(sb, table, i, MATERIAL_AIR)
				removed += 1

				if step <= CUT_SPRAY_NEAR do continue
				if sandbox_chance(sb, x, y, .Cut_Spray) & 255 >= CUT_SPRAY_CHANCE do continue

				back := CUT_SPRAY_NEAR + i32(sandbox_chance(sb, x, y, .Cut_Spray, 1) % u32(step - CUT_SPRAY_NEAR))
				across := i32(sandbox_chance(sb, x, y, .Cut_Spray, 2) % (2*CUT_SPRAY_ACROSS + 1)) - CUT_SPRAY_ACROSS
				sandbox_throw(
					sb,
					table,
					material,
					cx + i32(math.round(dx*f32(back) + px*f32(across))),
					cy + i32(math.round(dy*f32(back) + py*f32(across))),
				)
			}
		}
	}
	return removed
}

@(private = "file")
sandbox_throw :: proc(sb: ^Sandbox, table: Material_Table, material: Cell, tx, ty: i32) {
	debris := Cell(table.crumbles_to[material])
	if table.kind[debris] == .Still do return
	if !sandbox_in_bounds(sb, tx, ty) do return

	i := sandbox_index(sb, tx, ty)
	if sb.cells[i] != MATERIAL_AIR do return
	sandbox_put(sb, table, i, debris)
}

sandbox_census :: proc(sb: ^Sandbox, counts: []int) {
	slice.zero(counts)
	for c in sb.cells {
		if int(c) < len(counts) do counts[c] += 1
	}
}

@(private = "file")
test_sandbox :: proc(t: ^testing.T, width, height: i32, seed: u64) -> (Sandbox, Material_Table) {
	table, load_ok := load_materials("data/materials.txt")
	testing.expect(t, load_ok, "materials must load")

	sb, make_ok := sandbox_make(width, height, seed)
	testing.expect(t, make_ok, "the sandbox must be created")
	return sb, table
}

@(test)
test_sandbox_starts_empty :: proc(t: ^testing.T) {
	sb, table := test_sandbox(t, 16, 16, 1)
	defer sandbox_destroy(&sb)
	defer destroy_material_table(table)

	for c in sb.cells {
		testing.expect(t, c == MATERIAL_AIR, "a new sandbox must hold only air")
	}
	testing.expect(t, sb.tick == 0)
}

@(test)
test_powder_falls_to_the_floor :: proc(t: ^testing.T) {
	sb, table := test_sandbox(t, 8, 16, 7)
	defer sandbox_destroy(&sb)
	defer destroy_material_table(table)

	sand, _ := find_material_index(table, "Sand")
	sandbox_paint(&sb, table, 4, 0, 0, Cell(sand))

	for _ in 0 ..< 32 do sandbox_step(&sb, table)

	testing.expect(t, int(sandbox_cell(&sb, 4, sb.height-1)) == sand, "sand must rest on the floor")
	testing.expect(t, sandbox_cell(&sb, 4, 0) == MATERIAL_AIR, "the start cell must be empty")
}

@(test)
test_solid_never_moves :: proc(t: ^testing.T) {
	sb, table := test_sandbox(t, 8, 8, 3)
	defer sandbox_destroy(&sb)
	defer destroy_material_table(table)

	rock, _ := find_material_index(table, "Rock")
	sandbox_paint(&sb, table, 4, 2, 0, Cell(rock))

	for _ in 0 ..< 20 do sandbox_step(&sb, table)

	testing.expect(t, int(sandbox_cell(&sb, 4, 2)) == rock, "rock must stay in place")
}

@(test)
test_gas_rises_through_liquid :: proc(t: ^testing.T) {
	sb, table := test_sandbox(t, 8, 16, 11)
	defer sandbox_destroy(&sb)
	defer destroy_material_table(table)

	water, _ := find_material_index(table, "Water")
	smoke, _ := find_material_index(table, "Smoke")

	for y in i32(8) ..< 16 {
		for x in i32(0) ..< 8 do sandbox_paint(&sb, table, x, y, 0, Cell(water))
	}
	sandbox_paint(&sb, table, 4, 15, 0, Cell(smoke))

	start := sb.height
	for _ in 0 ..< 40 do sandbox_step(&sb, table)

	found := i32(-1)
	for y in i32(0) ..< sb.height {
		for x in i32(0) ..< sb.width {
			if int(sandbox_cell(&sb, x, y)) == smoke {
				found = y
				break
			}
		}
		if found >= 0 do break
	}
	testing.expect(t, found >= 0, "the smoke must still exist")
	testing.expect(t, found < start-1, "the smoke must climb")
}

@(test)
test_denser_powder_sinks_through_liquid :: proc(t: ^testing.T) {
	sb, table := test_sandbox(t, 8, 16, 5)
	defer sandbox_destroy(&sb)
	defer destroy_material_table(table)

	water, _ := find_material_index(table, "Water")
	sand, _ := find_material_index(table, "Sand")

	for y in i32(4) ..< 16 {
		for x in i32(0) ..< 8 do sandbox_paint(&sb, table, x, y, 0, Cell(water))
	}
	sandbox_paint(&sb, table, 4, 0, 0, Cell(sand))

	for _ in 0 ..< 60 do sandbox_step(&sb, table)

	deepest := i32(-1)
	for y in i32(0) ..< sb.height {
		for x in i32(0) ..< sb.width {
			if int(sandbox_cell(&sb, x, y)) == sand do deepest = y
		}
	}
	testing.expect(t, deepest == sb.height-1, "sand must sink to the floor")
}

@(test)
test_a_flat_liquid_layer_stays_still :: proc(t: ^testing.T) {
	sb, table := test_sandbox(t, 16, 8, 21)
	defer sandbox_destroy(&sb)
	defer destroy_material_table(table)

	water, _ := find_material_index(table, "Water")
	for x in i32(0) ..< 16 do sandbox_paint(&sb, table, x, 7, 0, Cell(water))

	for _ in 0 ..< 20 do sandbox_step(&sb, table)

	for x in i32(0) ..< 16 {
		testing.expect(t, int(sandbox_cell(&sb, x, 7)) == water, "the layer must stay whole")
	}
	for y in i32(0) ..< 7 {
		for x in i32(0) ..< 16 {
			testing.expect(t, sandbox_cell(&sb, x, y) == MATERIAL_AIR, "nothing must climb out")
		}
	}
}

@(test)
test_a_lighter_liquid_rises_through_a_heavier_one :: proc(t: ^testing.T) {
	sb, table := test_sandbox(t, 8, 24, 31)
	defer sandbox_destroy(&sb)
	defer destroy_material_table(table)

	water, _ := find_material_index(table, "Water")
	oil, _ := find_material_index(table, "Oil")

	for y in i32(12) ..< 18 {
		for x in i32(0) ..< 8 do sandbox_paint(&sb, table, x, y, 0, Cell(water))
	}
	for y in i32(18) ..< 24 {
		for x in i32(0) ..< 8 do sandbox_paint(&sb, table, x, y, 0, Cell(oil))
	}

	for _ in 0 ..< 200 do sandbox_step(&sb, table)

	lowest_oil := i32(-1)
	shallowest_water := i32(1 << 20)
	for y in i32(0) ..< sb.height {
		for x in i32(0) ..< sb.width {
			switch int(sandbox_cell(&sb, x, y)) {
			case oil:   if y > lowest_oil do lowest_oil = y
			case water: if y < shallowest_water do shallowest_water = y
			}
		}
	}
	testing.expect(t, lowest_oil >= 0, "the oil must still exist")
	testing.expectf(
		t,
		lowest_oil <= shallowest_water,
		"every oil cell must float above every water cell, but oil reaches %d and water starts at %d",
		lowest_oil, shallowest_water,
	)
}

@(test)
test_one_liquid_on_a_flat_floor_does_not_jitter :: proc(t: ^testing.T) {
	sb, table := test_sandbox(t, 12, 12, 41)
	defer sandbox_destroy(&sb)
	defer destroy_material_table(table)

	water, _ := find_material_index(table, "Water")
	for y in i32(8) ..< 12 {
		for x in i32(0) ..< 12 do sandbox_paint(&sb, table, x, y, 0, Cell(water))
	}
	for _ in 0 ..< 60 do sandbox_step(&sb, table)
	for _ in 0 ..< 60 do sandbox_step(&sb, table)

	for y in i32(8) ..< 12 {
		for x in i32(0) ..< 12 {
			testing.expect(t, int(sandbox_cell(&sb, x, y)) == water, "the pool must hold its shape")
		}
	}
}

@(test)
test_a_liquid_still_spreads_out :: proc(t: ^testing.T) {
	sb, table := test_sandbox(t, 32, 16, 22)
	defer sandbox_destroy(&sb)
	defer destroy_material_table(table)

	water, _ := find_material_index(table, "Water")
	for y in i32(8) ..< 16 do sandbox_paint(&sb, table, 16, y, 0, Cell(water))

	for _ in 0 ..< 60 do sandbox_step(&sb, table)

	width := 0
	for x in i32(0) ..< 32 {
		for y in i32(0) ..< 16 {
			if int(sandbox_cell(&sb, x, y)) == water {
				width += 1
				break
			}
		}
	}
	testing.expect(t, width > 4, "a column of water must spread along the floor")
}

@(test)
test_lifetime_turns_fire_into_smoke :: proc(t: ^testing.T) {
	sb, table := test_sandbox(t, 8, 8, 2)
	defer sandbox_destroy(&sb)
	defer destroy_material_table(table)

	fire, _ := find_material_index(table, "Fire")
	smoke, _ := find_material_index(table, "Smoke")

	sandbox_paint(&sb, table, 4, 7, 0, Cell(fire))

	counts := make([]int, len(table.materials))
	defer delete(counts)

	for _ in 0 ..< 95 do sandbox_step(&sb, table)
	sandbox_census(&sb, counts)

	testing.expect(t, counts[fire] == 0, "the fire must burn out")
	testing.expect(t, counts[smoke] == 1, "the fire must leave smoke")
}

@(test)
test_fire_spreads_through_oil :: proc(t: ^testing.T) {
	sb, table := test_sandbox(t, 32, 8, 13)
	defer sandbox_destroy(&sb)
	defer destroy_material_table(table)

	oil, _ := find_material_index(table, "Oil")
	rock, _ := find_material_index(table, "Rock")

	for x in i32(0) ..< 32 {
		sandbox_paint(&sb, table, x, 7, 0, Cell(rock))
		sandbox_paint(&sb, table, x, 6, 0, Cell(oil))
	}
	fire, _ := find_material_index(table, "Fire")
	sandbox_paint(&sb, table, 0, 6, 0, Cell(fire))

	counts := make([]int, len(table.materials))
	defer delete(counts)

	burned := false
	for _ in 0 ..< 300 {
		sandbox_step(&sb, table)
		sandbox_census(&sb, counts)
		if counts[oil] == 0 {
			burned = true
			break
		}
	}
	testing.expect(t, burned, "the fire must run along the oil")
}

@(test)
test_ignite_needs_fuel :: proc(t: ^testing.T) {
	sb, table := test_sandbox(t, 8, 8, 17)
	defer sandbox_destroy(&sb)
	defer destroy_material_table(table)

	oil, _ := find_material_index(table, "Oil")

	testing.expect(t, sandbox_ignite(&sb, table, 4, 4, 2) == 0, "air must not ignite")

	sandbox_paint(&sb, table, 4, 4, 0, Cell(oil))
	testing.expect(t, sandbox_ignite(&sb, table, 4, 4, 1) == 1, "oil must ignite")
}

@(test)
test_same_seed_gives_the_same_checksum :: proc(t: ^testing.T) {
	table, load_ok := load_materials("data/materials.txt")
	defer destroy_material_table(table)
	testing.expect(t, load_ok)

	sand, _ := find_material_index(table, "Sand")
	water, _ := find_material_index(table, "Water")

	run :: proc(table: Material_Table, seed: u64, sand, water: Cell) -> u64 {
		sb, _ := sandbox_make(48, 32, seed)
		defer sandbox_destroy(&sb)

		for step in 0 ..< 120 {
			if step % 10 == 0 {
				sandbox_paint(&sb, table, 24, 0, 3, sand)
				sandbox_paint(&sb, table, 10, 0, 2, water)
			}
			sandbox_step(&sb, table)
		}
		return sandbox_checksum(&sb)
	}

	a := run(table, 12345, Cell(sand), Cell(water))
	b := run(table, 12345, Cell(sand), Cell(water))
	c := run(table, 54321, Cell(sand), Cell(water))

	testing.expect(t, a == b, "the same seed must give the same world")
	testing.expect(t, a != c, "a different seed must give a different world")
}

@(test)
test_water_quenches_fire_into_steam :: proc(t: ^testing.T) {
	sb, table := test_sandbox(t, 8, 8, 9)
	defer sandbox_destroy(&sb)
	defer destroy_material_table(table)

	fire, _ := find_material_index(table, "Fire")
	steam, _ := find_material_index(table, "Steam")
	rock, _ := find_material_index(table, "Rock")
	water, _ := find_material_index(table, "Water")

	for x in i32(0) ..< 8 do sandbox_paint(&sb, table, x, 7, 0, Cell(rock))
	sandbox_paint(&sb, table, 4, 6, 0, Cell(fire))
	sandbox_paint(&sb, table, 4, 5, 0, Cell(water))

	counts := make([]int, len(table.materials))
	defer delete(counts)

	found := false
	for _ in 0 ..< 300 {
		sandbox_step(&sb, table)
		sandbox_census(&sb, counts)
		if counts[fire] == 0 && counts[steam] > 0 {
			found = true
			break
		}
	}
	testing.expect(t, found, "water must quench the fire and leave steam behind")
}

@(test)
test_water_on_lava_leaves_obsidian :: proc(t: ^testing.T) {
	sb, table := test_sandbox(t, 8, 16, 4)
	defer sandbox_destroy(&sb)
	defer destroy_material_table(table)

	lava, _ := find_material_index(table, "Lava")
	water, _ := find_material_index(table, "Water")
	obsidian, _ := find_material_index(table, "Obsidian")

	for x in i32(0) ..< 8 do sandbox_paint(&sb, table, x, 7, 0, Cell(lava))
	for x in i32(0) ..< 8 do sandbox_paint(&sb, table, x, 6, 0, Cell(water))

	counts := make([]int, len(table.materials))
	defer delete(counts)

	found := false
	for _ in 0 ..< 2000 {
		sandbox_step(&sb, table)
		sandbox_census(&sb, counts)
		if counts[obsidian] > 0 {
			found = true
			break
		}
	}
	testing.expect(t, found, "water meeting lava must leave obsidian")
}

@(test)
test_acid_eats_rock_and_runs_out :: proc(t: ^testing.T) {
	sb, table := test_sandbox(t, 6, 30, 6)
	defer sandbox_destroy(&sb)
	defer destroy_material_table(table)

	acid, _ := find_material_index(table, "Acid")
	rock, _ := find_material_index(table, "Rock")

	for y in i32(0) ..< 3 {
		for x in i32(0) ..< 6 do sandbox_paint(&sb, table, x, y, 0, Cell(acid))
	}
	for y in i32(3) ..< 30 {
		for x in i32(0) ..< 6 do sandbox_paint(&sb, table, x, y, 0, Cell(rock))
	}
	rock_start := 6 * 27

	counts := make([]int, len(table.materials))
	defer delete(counts)

	for _ in 0 ..< 6000 do sandbox_step(&sb, table)
	sandbox_census(&sb, counts)

	testing.expect(t, counts[acid] == 0, "a small pool of acid must be used up")
	testing.expectf(
		t, counts[rock] > rock_start-6*3-1,
		"the pool must stop after eating roughly its own size of rock, not bore for ever: %d of %d left",
		counts[rock], rock_start,
	)
}

@(test)
test_wooden_beam_burns_to_ash_on_the_floor :: proc(t: ^testing.T) {
	sb, table := test_sandbox(t, 24, 8, 15)
	defer sandbox_destroy(&sb)
	defer destroy_material_table(table)

	wood, _ := find_material_index(table, "Wood")
	burning_wood, _ := find_material_index(table, "Burning_Wood")
	ash, _ := find_material_index(table, "Ash")
	rock, _ := find_material_index(table, "Rock")

	for x in i32(0) ..< 24 do sandbox_paint(&sb, table, x, 7, 0, Cell(rock))
	for x in i32(0) ..< 24 do sandbox_paint(&sb, table, x, 6, 0, Cell(wood))

	sandbox_ignite(&sb, table, 0, 6, 0)

	counts := make([]int, len(table.materials))
	defer delete(counts)

	burned_out := false
	for _ in 0 ..< 3000 {
		sandbox_step(&sb, table)
		sandbox_census(&sb, counts)
		if counts[wood] == 0 && counts[burning_wood] == 0 {
			burned_out = true
			break
		}
	}
	testing.expect(t, burned_out, "the whole beam must finish burning")
	testing.expect(t, counts[ash] == 24, "every cell of the beam must become ash")
	for x in i32(0) ..< 24 {
		testing.expectf(t, int(sandbox_cell(&sb, x, 6)) == ash, "cell %d must rest as ash on the floor", x)
	}
}

@(test)
test_explosion_casts_a_shadow_behind_bedrock :: proc(t: ^testing.T) {
	sb, table := test_sandbox(t, 41, 41, 3)
	defer sandbox_destroy(&sb)
	defer destroy_material_table(table)

	rock, _ := find_material_index(table, "Rock")
	bedrock, _ := find_material_index(table, "Bedrock")

	for y in i32(0) ..< 41 {
		for x in i32(0) ..< 41 do sandbox_paint(&sb, table, x, y, 0, Cell(rock))
	}
	for y in i32(15) ..< 20 {
		for x in i32(16) ..< 25 do sandbox_paint(&sb, table, x, y, 0, Cell(bedrock))
	}

	broken := sandbox_explode(&sb, table, 20, 30, 25, 255)
	testing.expect(t, broken > 0, "the blast must clear something")

	shadow_whole := true
	for y in i32(0) ..< 13 {
		for x in i32(18) ..< 23 {
			if int(sandbox_cell(&sb, x, y)) != rock do shadow_whole = false
		}
	}
	testing.expect(t, shadow_whole, "the shadow of the pillar must stay whole rock")

	side_cleared := false
	for y in i32(5) ..< 15 {
		for x in i32(0) ..< 15 {
			if sandbox_cell(&sb, x, y) == MATERIAL_AIR do side_cleared = true
		}
	}
	testing.expect(t, side_cleared, "the blast must clear rock beside the pillar, where nothing blocks the rays")
}

@(test)
test_blasted_rock_leaves_gravel_that_falls :: proc(t: ^testing.T) {
	sb, table := test_sandbox(t, 20, 20, 8)
	defer sandbox_destroy(&sb)
	defer destroy_material_table(table)

	rock, _ := find_material_index(table, "Rock")
	gravel, _ := find_material_index(table, "Gravel")

	for y in i32(0) ..< 20 {
		for x in i32(0) ..< 20 do sandbox_paint(&sb, table, x, y, 0, Cell(rock))
	}

	broken := sandbox_explode(&sb, table, 10, 5, 6, 80)
	testing.expect(t, broken > 0, "the blast must clear rock")

	counts := make([]int, len(table.materials))
	defer delete(counts)
	sandbox_census(&sb, counts)
	testing.expect(t, counts[gravel] > 0, "the rock crumbling at the crater edge must leave gravel")

	sum_y :: proc(sb: ^Sandbox, gravel: int) -> i64 {
		total: i64 = 0
		for y in i32(0) ..< sb.height {
			for x in i32(0) ..< sb.width {
				if int(sandbox_cell(sb, x, y)) == gravel do total += i64(y)
			}
		}
		return total
	}

	before := sum_y(&sb, gravel)
	for _ in 0 ..< 80 do sandbox_step(&sb, table)
	after := sum_y(&sb, gravel)

	testing.expect(t, after > before, "gravel is a powder, so it must fall once the blast opens space under it")
}

@(test)
test_gunpowder_pile_chain_detonates_and_leaves_a_crater :: proc(t: ^testing.T) {
	sb, table := test_sandbox(t, 40, 40, 21)
	defer sandbox_destroy(&sb)
	defer destroy_material_table(table)

	gunpowder, _ := find_material_index(table, "Gunpowder")

	for y in i32(5) ..< 35 {
		for x in i32(5) ..< 35 do sandbox_paint(&sb, table, x, y, 0, Cell(gunpowder))
	}
	start_count := 30 * 30

	sandbox_ignite(&sb, table, 20, 20, 0)

	for _ in 0 ..< 5000 do sandbox_step(&sb, table)

	counts := make([]int, len(table.materials))
	defer delete(counts)
	sandbox_census(&sb, counts)

	testing.expectf(
		t, counts[gunpowder] < start_count/2,
		"the pile must have detonated down substantially: %d of %d grains left",
		counts[gunpowder], start_count,
	)
	testing.expect(t, counts[int(MATERIAL_AIR)] > 0, "the blast must leave a crater of air")
}

@(test)
test_dig_removes_rock_but_not_steel_or_bedrock :: proc(t: ^testing.T) {
	sb, table := test_sandbox(t, 10, 4, 1)
	defer sandbox_destroy(&sb)
	defer destroy_material_table(table)

	rock, _ := find_material_index(table, "Rock")
	steel, _ := find_material_index(table, "Steel")
	bedrock, _ := find_material_index(table, "Bedrock")

	sandbox_paint(&sb, table, 2, 2, 0, Cell(rock))
	sandbox_paint(&sb, table, 5, 2, 0, Cell(steel))
	sandbox_paint(&sb, table, 8, 2, 0, Cell(bedrock))

	removed := sandbox_dig(&sb, table, 2, 2, 0, 8)
	testing.expect(t, removed == 1, "rock at exactly the wizard's power must be dug")
	testing.expect(t, sandbox_cell(&sb, 2, 2) == MATERIAL_AIR, "the rock cell must be gone")

	removed_steel := sandbox_dig(&sb, table, 5, 2, 0, 8)
	testing.expect(t, removed_steel == 0, "steel must resist the wizard's dig power")
	testing.expect(t, int(sandbox_cell(&sb, 5, 2)) == steel, "steel must still be there")

	removed_bedrock := sandbox_dig(&sb, table, 8, 2, 0, 8)
	testing.expect(t, removed_bedrock == 0, "bedrock must resist the wizard's dig power")
	testing.expect(t, int(sandbox_cell(&sb, 8, 2)) == bedrock, "bedrock must still be there")
}

@(test)
test_a_cut_throws_its_cuttings_and_replays_them_exactly :: proc(t: ^testing.T) {
	table, load_ok := load_materials("data/materials.txt")
	defer destroy_material_table(table)
	testing.expect(t, load_ok, "materials must load")

	rock, _ := find_material_index(table, "Rock")

	run :: proc(table: Material_Table, rock: int) -> (checksum: u64, gravel_count: int, removed: int) {
		sb, _ := sandbox_make(96, 96, 7)
		defer sandbox_destroy(&sb)
		for i in 0 ..< len(sb.cells) do sb.cells[i] = Cell(rock)

		removed = sandbox_cut(&sb, table, 48, 48, 1, 0, 40, 3, 8)

		counts := make([]int, len(table.materials))
		defer delete(counts)
		sandbox_census(&sb, counts)
		gravel_index, _ := find_material_index(table, "Gravel")
		return sandbox_checksum(&sb), counts[gravel_index], removed
	}

	first, gravel_first, removed := run(table, rock)
	second, gravel_second, removed_again := run(table, rock)

	testing.expect(t, removed > 0, "a beam through rock must cut something")
	testing.expect(t, gravel_first > 0, "rock crumbles into gravel: some of the cut must fly")
	testing.expectf(
		t, gravel_first < removed/2,
		"most of a cut must be vapour, got %d grains of %d cells cut", gravel_first, removed,
	)
	testing.expect(t, first == second, "the same seed must cut and scatter the same way twice")
	testing.expect(t, gravel_first == gravel_second && removed == removed_again, "and throw the same number of grains")
}

@(test)
test_a_cut_stops_at_material_harder_than_its_power :: proc(t: ^testing.T) {
	sb, table := test_sandbox(t, 32, 8, 1)
	defer sandbox_destroy(&sb)
	defer destroy_material_table(table)

	rock, _ := find_material_index(table, "Rock")
	bedrock, _ := find_material_index(table, "Bedrock")
	for i in 0 ..< len(sb.cells) do sb.cells[i] = Cell(rock)
	for y in i32(0) ..< sb.height do sb.cells[sandbox_index(&sb, 10, y)] = Cell(bedrock)

	sandbox_cut(&sb, table, 0, 4, 1, 0, 30, 0, 8)

	testing.expect(t, sandbox_cell(&sb, 9, 4) == MATERIAL_AIR, "everything short of the bedrock must be cut")
	testing.expect(t, int(sandbox_cell(&sb, 10, 4)) == bedrock, "the bedrock itself must stand")
	testing.expect(t, int(sandbox_cell(&sb, 11, 4)) == rock, "and the beam must not reach past it")
}

@(test)
test_same_seed_gives_the_same_checksum_with_explode_and_dig :: proc(t: ^testing.T) {
	table, load_ok := load_materials("data/materials.txt")
	defer destroy_material_table(table)
	testing.expect(t, load_ok)

	sand, _ := find_material_index(table, "Sand")
	water, _ := find_material_index(table, "Water")
	rock, _ := find_material_index(table, "Rock")
	gunpowder, _ := find_material_index(table, "Gunpowder")

	run :: proc(table: Material_Table, seed: u64, sand, water, rock, gunpowder: Cell) -> u64 {
		sb, _ := sandbox_make(48, 32, seed)
		defer sandbox_destroy(&sb)

		for y in i32(20) ..< 32 {
			for x in i32(0) ..< 48 do sandbox_paint(&sb, table, x, y, 0, rock)
		}

		for step in 0 ..< 200 {
			switch step {
			case 0:
				sandbox_paint(&sb, table, 24, 0, 3, sand)
				sandbox_paint(&sb, table, 10, 0, 2, water)
			case 40:
				sandbox_paint(&sb, table, 30, 10, 3, gunpowder)
			case 60:
				sandbox_explode(&sb, table, 30, 10, 6, 60)
			case 100:
				sandbox_dig(&sb, table, 20, 25, 4, 8)
			}
			sandbox_step(&sb, table)
		}
		return sandbox_checksum(&sb)
	}

	a := run(table, 777, Cell(sand), Cell(water), Cell(rock), Cell(gunpowder))
	b := run(table, 777, Cell(sand), Cell(water), Cell(rock), Cell(gunpowder))
	c := run(table, 999, Cell(sand), Cell(water), Cell(rock), Cell(gunpowder))

	testing.expect(t, a == b, "the same seed and the same command list must give the same checksum")
	testing.expect(t, a != c, "a different seed must still diverge")
}

@(test)
test_a_long_settled_pile_wakes_when_the_floor_is_dug_out :: proc(t: ^testing.T) {
	sb, table := test_sandbox(t, 16, 20, 50)
	defer sandbox_destroy(&sb)
	defer destroy_material_table(table)

	rock, _ := find_material_index(table, "Rock")
	sand, _ := find_material_index(table, "Sand")

	for x in i32(0) ..< 16 do sandbox_paint(&sb, table, x, 15, 0, Cell(rock))
	for y in i32(10) ..< 15 {
		for x in i32(4) ..< 12 do sandbox_paint(&sb, table, x, y, 0, Cell(sand))
	}

	for _ in 0 ..< 500 do sandbox_step(&sb, table)
	testing.expect(t, int(sandbox_cell(&sb, 8, 14)) == sand, "the pile must have settled onto the floor and slept")

	sandbox_dig(&sb, table, 8, 15, 1, 8)

	for _ in 0 ..< 200 do sandbox_step(&sb, table)

	testing.expect(t, sandbox_cell(&sb, 8, 14) == MATERIAL_AIR, "sand above the hole must have left its old spot")
	fell_through := false
	for y in i32(15) ..< 20 {
		if int(sandbox_cell(&sb, 8, y)) == sand do fell_through = true
	}
	testing.expect(t, fell_through, "sand must have fallen through the hole dug in the floor under it")
}

@(test)
test_a_grain_on_a_chunk_border_still_falls_across_it :: proc(t: ^testing.T) {
	sb, table := test_sandbox(t, 128, 16, 40)
	defer sandbox_destroy(&sb)
	defer destroy_material_table(table)

	rock, _ := find_material_index(table, "Rock")
	sand, _ := find_material_index(table, "Sand")

	for x in i32(0) ..< 128 do sandbox_paint(&sb, table, x, 10, 0, Cell(rock))
	sandbox_paint(&sb, table, 63, 9, 0, Cell(sand))

	for _ in 0 ..< 400 do sandbox_step(&sb, table)
	testing.expect(t, int(sandbox_cell(&sb, 63, 9)) == sand, "the grain must have settled and slept on the floor")

	sandbox_dig(&sb, table, 64, 10, 0, 8)

	for _ in 0 ..< 50 do sandbox_step(&sb, table)

	testing.expect(t, sandbox_cell(&sb, 63, 9) == MATERIAL_AIR, "the grain must have left its resting cell on the border")
	testing.expect(t, int(sandbox_cell(&sb, 64, sb.height-1)) == sand, "the grain must have fallen across the chunk border and down the open column")
}

@(test)
test_fire_in_open_air_still_becomes_smoke_with_nothing_else_to_keep_it_awake :: proc(t: ^testing.T) {
	sb, table := test_sandbox(t, 4, 4, 60)
	defer sandbox_destroy(&sb)
	defer destroy_material_table(table)

	fire, _ := find_material_index(table, "Fire")
	rock, _ := find_material_index(table, "Rock")
	smoke, _ := find_material_index(table, "Smoke")

	sandbox_paint(&sb, table, 1, 0, 0, Cell(rock))
	sandbox_paint(&sb, table, 0, 0, 0, Cell(fire))

	counts := make([]int, len(table.materials))
	defer delete(counts)

	for _ in 0 ..< 95 do sandbox_step(&sb, table)
	sandbox_census(&sb, counts)

	testing.expect(t, counts[fire] == 0, "the fire must burn out even though it never moved or touched a neighbour")
	testing.expect(t, counts[smoke] > 0, "the fire must still leave smoke")
}

@(test)
test_same_seed_gives_the_same_checksum_after_sleeping_and_waking :: proc(t: ^testing.T) {
	table, load_ok := load_materials("data/materials.txt")
	defer destroy_material_table(table)
	testing.expect(t, load_ok)

	sand, _ := find_material_index(table, "Sand")
	rock, _ := find_material_index(table, "Rock")

	run :: proc(table: Material_Table, seed: u64, sand, rock: Cell) -> u64 {
		sb, _ := sandbox_make(96, 24, seed)
		defer sandbox_destroy(&sb)

		for x in i32(0) ..< 96 do sandbox_paint(&sb, table, x, 20, 0, rock)
		for y in i32(10) ..< 20 {
			for x in i32(0) ..< 96 do sandbox_paint(&sb, table, x, y, 0, sand)
		}

		for step in 0 ..< 600 {
			if step == 400 {
				sandbox_dig(&sb, table, 10, 20, 3, 8)
				sandbox_dig(&sb, table, 80, 20, 3, 8)
			}
			sandbox_step(&sb, table)
		}
		return sandbox_checksum(&sb)
	}

	a := run(table, 314159, Cell(sand), Cell(rock))
	b := run(table, 314159, Cell(sand), Cell(rock))
	c := run(table, 271828, Cell(sand), Cell(rock))

	testing.expect(t, a == b, "the same seed and commands must give the same checksum after chunks sleep and wake")
	testing.expect(t, a != c, "a different seed must still diverge")
}
