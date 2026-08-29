package game

import "core:math"
import "core:mem"
import "core:slice"
import testing "check"

SANDBOX_MAX_WIDTH  :: 2048
SANDBOX_MAX_HEIGHT :: 2048

SANDBOX_CHUNK :: 64

EXPLODE_MIN_RAYS      :: 24
EXPLODE_RAYS_PER_CELL :: 6
EXPLODE_BLAST_ODDS    :: 150  // out of 255: how much of the inner blast catches

BLAST_LIFT      :: 16  // lift is energy per unit of weight, in sixteenths
BLAST_SCATTER   :: 24  // lift at which matter flies clear
BLAST_CRUMBLE   :: 8   // lift at which matter breaks up and falls
BLAST_CHIP      :: 2   // lift at which a blast still bites a face
BLAST_CHIP_ODDS :: 96  // out of 255: how much of a chipped face goes
BLAST_FLING     :: 2   // cells a scattered grain flies per unit of lift

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

	bangs:  Bang_Ring,
	sparks: Spark_Ring,

	dirty:      []Sandbox_Rect,
	next_dirty: []Sandbox_Rect,

	// A bit a row in each chunk, beside the rect. The rect alone wakes
	// every row between two marks; a lake surface is three live rows in
	// a chunk of 64, and the bits let the step walk only those three.
	dirty_rows:      []u64,
	next_dirty_rows: []u64,

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
	sb.dirty_rows = make([]u64, chunk_count, allocator)
	sb.next_dirty_rows = make([]u64, chunk_count, allocator)

	sb.rows.above = make([]u16, width + 2, allocator)
	sb.rows.here  = make([]u16, width + 2, allocator)
	sb.rows.below = make([]u16, width + 2, allocator)
	sb.rows.kind  = make([]Cell_Kind, width + 2, allocator)
	sb.rows.dx    = make([]i16, width, allocator)
	sb.rows.dy    = make([]i16, width, allocator)
	sb.rows.above[0], sb.rows.above[width + 1] = CELL_WALL, CELL_WALL
	sb.rows.here[0], sb.rows.here[width + 1] = CELL_WALL, CELL_WALL
	sb.rows.below[0], sb.rows.below[width + 1] = CELL_WALL, CELL_WALL

	bang_forget_all(&sb.bangs)
	spark_forget_all(&sb.sparks)

	return sb, true
}

sandbox_destroy :: proc(sb: ^Sandbox, allocator := context.allocator) {
	delete(sb.cells, allocator)
	delete(sb.lifetime, allocator)
	delete(sb.moved, allocator)
	delete(sb.dirty, allocator)
	delete(sb.next_dirty, allocator)
	delete(sb.dirty_rows, allocator)
	delete(sb.next_dirty_rows, allocator)
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
	bang_forget_all(&sb.bangs)
	spark_forget_all(&sb.sparks)

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
			sb.dirty_rows[ci] = max(u64)
			sb.next_dirty_rows[ci] = max(u64)
		}
	}
}

// The bits for the rows lo..hi of one chunk, both in 0..63.
sandbox_row_bits :: #force_inline proc "contextless" (lo, hi: i32) -> u64 {
	return (max(u64) << u64(lo)) & (max(u64) >> u64(63 - hi))
}

sandbox_mark :: proc(sb: ^Sandbox, x, y: i32) {
	sandbox_mark_box(sb, x-1, y-1, x+1, y+1)
}

// Wake the cells of a box, and their chunks with them. Nearly every box
// sits inside one chunk, and that case is four compares; only a box on
// a chunk border pays for the walk below.
sandbox_mark_box :: proc(sb: ^Sandbox, x0, y0, x1, y1: i32) {
	lo_x := max(x0, 0)
	hi_x := min(x1, sb.width-1)
	lo_y := max(y0, 0)
	hi_y := min(y1, sb.height-1)

	cx0 := lo_x / SANDBOX_CHUNK
	cx1 := hi_x / SANDBOX_CHUNK
	cy0 := lo_y / SANDBOX_CHUNK
	cy1 := hi_y / SANDBOX_CHUNK

	if cx0 == cx1 && cy0 == cy1 {
		ci := int(cy0*sb.chunks_x + cx0)
		r := &sb.next_dirty[ci]
		r.min_x = min(r.min_x, lo_x)
		r.min_y = min(r.min_y, lo_y)
		r.max_x = max(r.max_x, hi_x)
		r.max_y = max(r.max_y, hi_y)
		base := cy0 * SANDBOX_CHUNK
		sb.next_dirty_rows[ci] |= sandbox_row_bits(lo_y - base, hi_y - base)
		return
	}

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
			sb.next_dirty_rows[ci] |= sandbox_row_bits(cell_lo_y - chunk_y0, cell_hi_y - chunk_y0)
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
	Blast_Chip,
	Blast_Throw,
	Blast_Fire,
	Spark_Seed,
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
	// A material with no physical interaction is not matter, so no cell can
	// hold one. See docs/lighting.md, "Every light is a material".
	if material_is_phantom(table.materials[material]) do return 0

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

	// A material with an expulsive force goes off instead of burning. The
	// blast writes the cell it goes off in, so the grain becomes the bang.
	if m.force > 0 {
		sandbox_explode(sb, table, x, y, i32(m.force), m.force)
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

// Density says where a paid-for cell's matter goes. A pure function of the
// material and the energy a ray still carries there, so a test can hold it
// to the note without running a blast.
Blast_Verdict :: enum u8 {
	Scatter,
	Crumble,
	Chip,
	Char,
}

blast_lift :: proc(table: Material_Table, material: Cell, energy: i32) -> i32 {
	m := table.materials[material]
	heft := max(i32(m.density * BLAST_LIFT), 1)
	return energy * BLAST_LIFT / heft
}

blast_verdict :: proc(table: Material_Table, material: Cell, energy: i32) -> Blast_Verdict {
	lift := blast_lift(table, material, energy)
	crumbled := Cell(table.crumbles_to[material])

	switch {
	case lift >= BLAST_SCATTER || table.kind[material] != .Still:
		return .Scatter
	case lift >= BLAST_CRUMBLE && crumbled != material:
		return .Crumble
	case lift >= BLAST_CHIP:
		return .Chip
	case:
		return .Char
	}
}

sandbox_explode :: proc(sb: ^Sandbox, table: Material_Table, cx, cy: i32, radius: i32, power: u8) -> (broken: int) {
	r := radius < 0 ? 0 : radius
	if r == 0 || power == 0 do return 0
	if !sandbox_in_bounds(sb, cx, cy) do return 0

	rays := max(EXPLODE_MIN_RAYS, r*EXPLODE_RAYS_PER_CELL)
	inner_r := r / 3

	blast_cell := Cell(table.blast)
	fire_cell := Cell(table.fire)
	soot_cell := Cell(table.soot)

	// An explosion is a material. The cell it goes off in holds that material,
	// and the world remembers the place as a bang, so the light can throw it
	// and the eye can draw it for as long as the material lives. The blast
	// pays for that cell exactly as a ray pays for the cells it crosses, so a
	// blast set off inside what it cannot break leaves the cell standing.
	origin := sandbox_index(sb, cx, cy)
	if i32(table.materials[sb.cells[origin]].hardness)+1 <= i32(power) {
		sandbox_put(sb, table, origin, blast_cell)
		sb.moved[origin] = true
	}
	bang_add(&sb.bangs, table, cx, cy)

	for ray in 0 ..< rays {
		angle := f32(ray) / f32(rays) * 2 * math.PI
		dx := math.cos(angle)
		dy := math.sin(angle)
		px, py := -dy, dx

		energy := i32(power)
		prev := sandbox_index(sb, cx, cy)

		for step in i32(1) ..= r {
			x := cx + i32(math.round(dx * f32(step)))
			y := cy + i32(math.round(dy * f32(step)))
			if !sandbox_in_bounds(sb, x, y) do break

			i := sandbox_index(sb, x, y)
			material := sb.cells[i]
			cost := i32(table.materials[material].hardness) + 1
			if energy < cost {
				if sandbox_char(sb, table, prev, i, soot_cell) do broken += 1
				break
			}
			energy -= cost

			if material == MATERIAL_AIR || material == fire_cell || material == blast_cell || sb.moved[i] {
				prev = i
				continue
			}

			crumbled := Cell(table.crumbles_to[material])

			switch blast_verdict(table, material, energy) {
			case .Scatter:
				broken += 1
				target := MATERIAL_AIR
				if step <= inner_r && sandbox_chance(sb, x, y, .Blast_Fire)&255 < EXPLODE_BLAST_ODDS {
					target = blast_cell
				}
				sandbox_put(sb, table, i, target)
				sb.moved[i] = true
				sandbox_crumble_neighbours(sb, table, x, y)

				if crumbled != material {
					lift := blast_lift(table, material, energy)
					over := max(lift-BLAST_SCATTER, 0)
					fly := min(step+BLAST_FLING*over/16, 2*r)
					side := i32(sandbox_chance(sb, x, y, .Blast_Throw)%3) - 1
					tx := cx + i32(math.round(dx*f32(fly) + px*f32(side)))
					ty := cy + i32(math.round(dy*f32(fly) + py*f32(side)))
					sandbox_throw(sb, table, crumbled, tx, ty)
				}

			case .Crumble:
				broken += 1
				sandbox_put(sb, table, i, crumbled)
				sb.moved[i] = true

			case .Chip:
				if sandbox_chance(sb, x, y, .Blast_Chip)&255 < BLAST_CHIP_ODDS {
					broken += 1
					sandbox_put(sb, table, i, MATERIAL_AIR)
					sb.moved[i] = true
					sandbox_crumble_neighbours(sb, table, x, y)
				} else if sandbox_char(sb, table, prev, i, soot_cell) {
					broken += 1
				}

			case .Char:
				if sandbox_char(sb, table, prev, i, soot_cell) do broken += 1
			}

			prev = i
		}
	}
	return broken
}

@(private = "file")
sandbox_char :: proc(sb: ^Sandbox, table: Material_Table, at, hit: int, soot: Cell) -> bool {
	if sb.cells[at] != MATERIAL_AIR do return false
	if sb.cells[hit] == MATERIAL_AIR do return false

	sandbox_put(sb, table, at, soot)
	sb.moved[at] = true
	return true
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

// How far a cut carries: the last step the digger can cut, walked from
// the centre along the aim. One procedure decides it, because two
// things measure from it and must agree or the picture lies about the
// tool: the kerf sandbox_cut opens, and the beam the window draws.
// `hit` says the walk stopped on a cell too hard to cut, rather than at
// the range or at the edge of the sandbox.
sandbox_cut_reach :: proc(
	sb: ^Sandbox,
	table: Material_Table,
	cx, cy: i32,
	dx, dy: f32,
	range: i32,
	power: u8,
) -> (reach: i32, hit: bool) {
	for step in i32(1) ..= range {
		ax := cx + i32(math.round(dx * f32(step)))
		ay := cy + i32(math.round(dy * f32(step)))
		if !sandbox_in_bounds(sb, ax, ay) do return reach, false
		if table.materials[sb.cells[sandbox_index(sb, ax, ay)]].hardness > power do return reach, true
		reach = step
	}
	return reach, false
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

	reach, _ := sandbox_cut_reach(sb, table, cx, cy, dx, dy, range, power)

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
	sb.moved[i] = true
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

// Brush is porous: what falls on a crop mostly sifts down through it
// to gather at its foot, the stalks riding up over the drift, and a
// little lodges in the weave on the way down. See sandbox_sift.
@(test)
test_what_falls_on_a_crop_mostly_sifts_through_and_a_little_lodges :: proc(t: ^testing.T) {
	for name in ([]string{"Sand", "Water"}) {
		sb, table := test_sandbox(t, 40, 48, 9)
		defer sandbox_destroy(&sb)
		defer destroy_material_table(table)

		wheat, wheat_found := find_material_index(table, "Wheat")
		if !testing.expect(t, wheat_found, "Wheat must exist") do return
		grain, grain_found := find_material_index(table, name)
		if !testing.expect(t, grain_found, "the falling material must exist") do return
		rock, _ := find_material_index(table, "Rock")

		// A floor, a standing crop eleven cells tall over the whole
		// width, and a row of what falls resting well above it.
		for x in i32(0) ..< sb.width {
			sandbox_paint(&sb, table, x, 40, 0, Cell(rock))
			for y in i32(29) ..< 40 do sandbox_paint(&sb, table, x, y, 0, Cell(wheat))
			sandbox_paint(&sb, table, x, 24, 0, Cell(grain))
		}

		for _ in 0 ..< 200 do sandbox_step(&sb, table)

		through, lodged, standing := 0, 0, 0
		for y in i32(0) ..< sb.height {
			for x in i32(0) ..< sb.width {
				c := int(sandbox_cell(&sb, x, y))
				if c == grain {
					if y >= 38 {through += 1} else {lodged += 1}
				}
				if c == wheat do standing += 1
			}
		}

		testing.expectf(
			t, through >= int(sb.width) * 3 / 4,
			"%s must mostly sift through the crop to its foot, and only %d of %d cells did",
			name, through, sb.width,
		)
		testing.expectf(
			t, lodged >= 1,
			"a little of the %s must lodge in the weave, and none did",
			name,
		)
		testing.expectf(
			t, standing == int(sb.width) * 11,
			"the crop must ride over what sifts through it, not be eaten: %d cells stand of %d",
			standing, int(sb.width) * 11,
		)
	}
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

// Attor and water, banded a cell at a time so every cell of one touches a
// cell of the other and the sealed column has no cell left stranded behind
// a settled wall of Smylt, where the physics has no way to reach it back
// (docs/physics.md, "no pressure, and no sideways exchange between
// liquids"). Scaled up to a stable sample. See docs/alchemy.md, "The mix":
// the pair always reacts, and the neutral share the pool settles to is 2/3
// within a percent.
@(test)
test_the_mix_leaves_two_parts_in_three :: proc(t: ^testing.T) {
	sb, table := test_sandbox(t, 10, 200, 7)
	defer sandbox_destroy(&sb)
	defer destroy_material_table(table)

	attor, _ := find_material_index(table, "Attor")
	water, _ := find_material_index(table, "Water")
	smylt, _ := find_material_index(table, "Smylt")
	sparkle, _ := find_material_index(table, "Sparkle")

	for y in i32(0) ..< 200 {
		m := y % 2 == 0 ? attor : water
		for x in i32(0) ..< 10 do sandbox_paint(&sb, table, x, y, 0, Cell(m))
	}
	total := 10 * 200

	counts := make([]int, len(table.materials))
	defer delete(counts)

	settled := false
	for _ in 0 ..< 4000 {
		sandbox_step(&sb, table)
		sandbox_census(&sb, counts)
		if counts[attor] == 0 && counts[water] == 0 {
			settled = true
			break
		}
	}
	if !testing.expect(t, settled, "the mix must run to a standstill with no Attor and no Water left") {
		return
	}

	// A few more ticks past the sparkle lifetime, so every spark has decayed
	// to Air and only the Smylt it left behind can be counted.
	for _ in 0 ..< 20 do sandbox_step(&sb, table)
	sandbox_census(&sb, counts)

	testing.expect(t, counts[attor] == 0, "no Attor may be left")
	testing.expect(t, counts[water] == 0, "no Water may be left")
	testing.expectf(t, counts[sparkle] == 0, "every spark must have decayed by now, got %d", counts[sparkle])

	share := f64(counts[smylt]) / f64(total)
	testing.expectf(
		t, abs(share-2.0/3.0) < 0.01,
		"the neutral liquid must settle to 2/3 of the pool within a percent, got %v of %d (%v)",
		counts[smylt], total, share,
	)
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
test_a_blast_scatters_light_matter_and_only_chips_heavy_matter :: proc(t: ^testing.T) {
	survivors :: proc(t: ^testing.T, name: string) -> (left, total: int) {
		sb, table := test_sandbox(t, 40, 40, 5)
		defer sandbox_destroy(&sb)
		defer destroy_material_table(table)

		material, found := find_material_index(table, name)
		if !testing.expectf(t, found, "%s must exist", name) do return 0, 1

		for y in i32(0) ..< 40 {
			for x in i32(0) ..< 40 do sandbox_paint(&sb, table, x, y, 0, Cell(material))
		}

		r := i32(12)
		sandbox_explode(&sb, table, 20, 20, r, 90)

		for y in i32(0) ..< 40 {
			for x in i32(0) ..< 40 {
				dx := x - 20
				dy := y - 20
				if dx*dx+dy*dy > r*r do continue
				total += 1
				if int(sandbox_cell(&sb, x, y)) == material do left += 1
			}
		}
		return left, total
	}

	dirt_left, dirt_total := survivors(t, "Dirt")
	gold_left, gold_total := survivors(t, "Gold")

	testing.expectf(
		t, dirt_left < dirt_total/4,
		"loose dirt must scatter clear of most of the blast, %d of %d left",
		dirt_left, dirt_total,
	)
	testing.expectf(
		t, gold_left > gold_total/2,
		"gold is heavy and has nothing to crumble into, so it must mostly stand, %d of %d left",
		gold_left, gold_total,
	)
}

@(test)
test_a_blast_against_bedrock_leaves_soot_on_its_face_and_the_wall_whole :: proc(t: ^testing.T) {
	sb, table := test_sandbox(t, 30, 10, 9)
	defer sandbox_destroy(&sb)
	defer destroy_material_table(table)

	bedrock, _ := find_material_index(table, "Bedrock")
	soot, _ := find_material_index(table, "Soot")

	for y in i32(0) ..< 10 do sandbox_paint(&sb, table, 20, y, 0, Cell(bedrock))

	sandbox_explode(&sb, table, 5, 5, 20, 200)

	testing.expectf(
		t, int(sandbox_cell(&sb, 20, 5)) == bedrock,
		"nothing must dent bedrock, and the cell the ray stopped at holds %s",
		table.names[sandbox_cell(&sb, 20, 5)],
	)
	testing.expectf(
		t, int(sandbox_cell(&sb, 19, 5)) == soot,
		"the air against the wall must char with soot, and it holds %s",
		table.names[sandbox_cell(&sb, 19, 5)],
	)

	// The blast pays for the cell it goes off in the way a ray pays for the
	// cells it crosses, so one set off inside bedrock leaves it standing.
	sandbox_explode(&sb, table, 20, 2, 20, 200)
	testing.expectf(
		t, int(sandbox_cell(&sb, 20, 2)) == bedrock,
		"a blast inside bedrock must not even write itself there, and the cell holds %s",
		table.names[sandbox_cell(&sb, 20, 2)],
	)
}

@(test)
test_a_blast_in_a_room_throws_matter_clear_of_its_own_radius :: proc(t: ^testing.T) {
	sb, table := test_sandbox(t, 90, 90, 4)
	defer sandbox_destroy(&sb)
	defer destroy_material_table(table)

	rock, _ := find_material_index(table, "Rock")
	gravel, _ := find_material_index(table, "Gravel")

	sandbox_paint(&sb, table, 45, 45, 2, Cell(rock))

	r := i32(4)
	sandbox_explode(&sb, table, 45, 45, r, 200)

	thrown_clear := false
	for y in i32(0) ..< 90 {
		for x in i32(0) ..< 90 {
			if int(sandbox_cell(&sb, x, y)) != gravel do continue
			dx := x - 45
			dy := y - 45
			if dx*dx+dy*dy > r*r do thrown_clear = true
		}
	}
	testing.expect(t, thrown_clear, "a scattered grain must be able to land past the blast's own radius")
}

@(test)
test_a_pot_grades_the_shipped_materials_as_the_note_says :: proc(t: ^testing.T) {
	table, load_ok := load_materials("data/materials.txt")
	defer destroy_material_table(table)
	if !testing.expect(t, load_ok, "materials must load") do return

	power := i32(pot_power(table))

	Case :: struct {
		name:    string,
		verdict: Blast_Verdict,
	}
	// docs/physics.md, "Under a pot's blast": the rung each material lands
	// on at point blank, which is the most a pot's own power can ever lift
	// it, since lift only falls further into the blast.
	cases := []Case {
		{"Gunpowder", .Scatter},
		{"Ash", .Scatter},
		{"Snow", .Scatter},
		{"Dirt", .Scatter},
		{"Sand", .Scatter},
		{"Wood", .Scatter},
		{"Ice", .Scatter},
		{"Rock", .Crumble},
		{"Coal", .Chip},
		{"Obsidian", .Chip},
		{"Steel", .Chip},
		{"Gold", .Char},
	}

	for c in cases {
		idx, found := find_material_index(table, c.name)
		if !testing.expectf(t, found, "%s must exist", c.name) do continue

		material := Cell(idx)
		energy := power - i32(table.materials[material].hardness) - 1
		got := blast_verdict(table, material, energy)
		testing.expectf(
			t, got == c.verdict,
			"the note says a pot's blast grades %s as %v at point blank, got %v (power %d, energy %d)",
			c.name, c.verdict, got, power, energy,
		)
	}

	bedrock, found := find_material_index(table, "Bedrock")
	if testing.expect(t, found, "Bedrock must exist") {
		cost := i32(table.materials[bedrock].hardness) + 1
		testing.expectf(
			t, power < cost,
			"the note says a pot's blast never reaches bedrock, but its cost of %d is not past a power of %d",
			cost, power,
		)
	}
}

@(test)
test_a_blast_is_made_of_a_material_that_decays_very_quickly :: proc(t: ^testing.T) {
	sb, table := test_sandbox(t, 60, 60, 3)
	defer sandbox_destroy(&sb)
	defer destroy_material_table(table)

	dirt, _ := find_material_index(table, "Dirt")
	for y in i32(0) ..< 60 {
		for x in i32(0) ..< 60 do sandbox_paint(&sb, table, x, y, 0, Cell(dirt))
	}

	sandbox_explode(&sb, table, 30, 30, 18, 90)

	counts := make([]int, len(table.materials))
	defer delete(counts)
	sandbox_census(&sb, counts)

	blast := int(table.blast)
	testing.expect(
		t, counts[blast] > 0,
		"the heart of the crater must hold the material a blast is made of, and it holds none",
	)
	testing.expectf(
		t, int(sandbox_cell(&sb, 30, 30)) == blast,
		"the cell the blast went off in must hold it, and it holds %s",
		table.names[sandbox_cell(&sb, 30, 30)],
	)

	life := int(table.materials[blast].lifetime)
	testing.expectf(
		t, life > 0 && life < int(table.materials[table.fire].lifetime),
		"a blast must decay far quicker than the fire it leaves, %d ticks against %d",
		life, table.materials[table.fire].lifetime,
	)

	for _ in 0 ..< life + 2 do sandbox_step(&sb, table)

	for &c in counts do c = 0
	sandbox_census(&sb, counts)
	testing.expectf(
		t, counts[blast] == 0,
		"and every cell of it must be gone a couple of ticks after its life ends, %d left",
		counts[blast],
	)
}

@(test)
test_a_cell_can_never_hold_a_material_with_no_physical_interaction :: proc(t: ^testing.T) {
	sb, table := test_sandbox(t, 16, 16, 1)
	defer sandbox_destroy(&sb)
	defer destroy_material_table(table)

	for light in ([]u16{table.orb, table.crystal, table.firefly}) {
		phantom := material_is_phantom(table.materials[light])
		if !testing.expectf(t, phantom, "%s must have no physical interaction", table.names[light]) {
			continue
		}

		changed := sandbox_paint(&sb, table, 8, 8, 2, Cell(light))
		testing.expectf(
			t, changed == 0,
			"the sandbox must refuse %s, and it took %d cells of it",
			table.names[light], changed,
		)
		testing.expectf(
			t, sandbox_cell(&sb, 8, 8) == MATERIAL_AIR,
			"and the cell must be untouched, and it holds %s",
			table.names[sandbox_cell(&sb, 8, 8)],
		)
	}
}

@(test)
test_the_same_blast_twice_gives_the_same_checksum :: proc(t: ^testing.T) {
	run :: proc(t: ^testing.T) -> u64 {
		sb, table := test_sandbox(t, 40, 40, 12)
		defer sandbox_destroy(&sb)
		defer destroy_material_table(table)

		rock, _ := find_material_index(table, "Rock")
		for y in i32(0) ..< 40 {
			for x in i32(0) ..< 40 do sandbox_paint(&sb, table, x, y, 0, Cell(rock))
		}
		sandbox_explode(&sb, table, 20, 20, 15, 150)
		for _ in 0 ..< 60 do sandbox_step(&sb, table)
		return sandbox_checksum(&sb)
	}

	testing.expect(t, run(t) == run(t), "the same blast must give the same checksum both times")
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
