package game

import "base:intrinsics"
import "core:mem"

sandbox_sinks :: #force_inline proc "contextless" (src, dst: u16) -> bool {
	return dst < src
}

sandbox_heavier :: #force_inline proc "contextless" (src, dst: u16) -> bool {
	return dst > src && dst != CELL_WALL
}

sandbox_rises :: #force_inline proc "contextless" (src, dst: u16) -> bool {
	return dst == CELL_AIR || sandbox_heavier(src, dst)
}

sandbox_spreads :: #force_inline proc "contextless" (self, side, below_side, above, above_side: u16) -> bool {
	room      := side == CELL_AIR
	unclaimed := above_side == CELL_AIR || above_side == CELL_WALL
	downhill  := below_side == CELL_AIR
	pressed   := above >= self && above != CELL_WALL
	return room && unclaimed && (downhill || pressed)
}

sandbox_weight_at :: #force_inline proc(sb: ^Sandbox, table: Material_Table, x, y: i32) -> u16 {
	if !sandbox_in_bounds(sb, x, y) do return CELL_WALL
	i := sandbox_index(sb, x, y)
	if sb.moved[i] do return CELL_WALL
	return table.weight[sb.cells[i]]
}

sandbox_step :: proc(sb: ^Sandbox, table: Material_Table) {
	wake := prof_begin()
	sb.dirty, sb.next_dirty = sb.next_dirty, sb.dirty
	sb.dirty_rows, sb.next_dirty_rows = sb.next_dirty_rows, sb.dirty_rows
	for &r in sb.next_dirty do r = SANDBOX_RECT_EMPTY
	mem.zero_slice(sb.next_dirty_rows)

	for r, ci in sb.dirty {
		if r.min_x > r.max_x do continue
		width := int(r.max_x - r.min_x + 1)
		base_y := i32(ci) / sb.chunks_x * SANDBOX_CHUNK
		for bits := sb.dirty_rows[ci]; bits != 0; bits &= bits - 1 {
			y := base_y + i32(intrinsics.count_trailing_zeros(bits))
			if y < r.min_y || y > r.max_y do continue
			row_start := sandbox_index(sb, r.min_x, y)
			mem.zero_slice(sb.moved[row_start:row_start + width])
		}
	}
	prof_end(.Step_Wake, wake)

	rows := prof_begin()
	for y := sb.height - 1; y >= 0; y -= 1 {
		cy := y / SANDBOX_CHUNK
		bit := u64(1) << u64(y & (SANDBOX_CHUNK - 1))
		chunk_row := sb.dirty[cy * sb.chunks_x:(cy + 1) * sb.chunks_x]
		row_bits := sb.dirty_rows[cy * sb.chunks_x:(cy + 1) * sb.chunks_x]
		for r, k in chunk_row {
			if row_bits[k] & bit == 0 do continue // nothing on this row
			sandbox_step_row(sb, table, y, r.min_x, r.max_x)
		}
	}
	prof_end(.Step_Rows, rows)

	age := prof_begin()
	bang_age(&sb.bangs)
	spark_age(&sb.sparks)
	prof_end(.Step_Age, age)

	sb.tick += 1
	prof.ticks += 1
}

sandbox_step_row :: proc(sb: ^Sandbox, table: Material_Table, y, x0, x1: i32) {
	prof.count[.Rows_Stepped] += 1
	prof.count[.Cells_Loaded] += int(x1 - x0 + 1)

	if sandbox_load_row(sb, table, y, x0, x1) {
		prof.count[.Hot_Rows] += 1
		if sandbox_hot_row(sb, table, y, x0, x1) {
			sandbox_load_row(sb, table, y, x0, x1)
		}
	}
	if sandbox_intent_row(sb, y, x0, x1) {
		prof.count[.Moving_Rows] += 1
		sandbox_apply_row(sb, table, y, x0, x1)
	}
}

sandbox_load_row :: proc(sb: ^Sandbox, table: Material_Table, y, x0, x1: i32) -> (hot: bool) {
	lo := max(x0 - 1, 0)
	hi := min(x1 + 1, sb.width - 1)
	r  := &sb.rows

	sandbox_load_weights(sb, table, r.above, y - 1, lo, hi)
	sandbox_load_weights(sb, table, r.below, y + 1, lo, hi)

	base := sandbox_index(sb, 0, y)
	for x in lo ..= hi {
		i    := base + int(x)
		c    := sb.cells[i]
		wall := u16(0) - u16(sb.moved[i])

		r.here[x + 1] = table.weight[c] | wall
		r.kind[x + 1] = Cell_Kind(u16(table.kind[c]) &~ wall)
		hot ||= (table.work[c] != {} || sb.lifetime[i] > 0) && !sb.moved[i]
	}
	return hot
}

sandbox_load_weights :: proc(sb: ^Sandbox, table: Material_Table, out: []u16, y, lo, hi: i32) {
	if y < 0 || y >= sb.height {
		for x in lo ..= hi do out[x + 1] = CELL_WALL
		return
	}
	base := sandbox_index(sb, 0, y)

	x := lo
	if table.wide_ok {
		for stop := sandbox_wide_start(lo, hi); x < stop; x += 1 {
			out[x + 1] = sandbox_weight_of(sb, table, base + int(x))
		}
		x = sandbox_weights_span(sb, table, out, base, x, hi)
	}
	for ; x <= hi; x += 1 {
		out[x + 1] = sandbox_weight_of(sb, table, base + int(x))
	}
}

sandbox_weight_of :: #force_inline proc(sb: ^Sandbox, table: Material_Table, i: int) -> u16 {
	return table.weight[sb.cells[i]] | (u16(0) - u16(sb.moved[i]))
}

sandbox_hot_row :: proc(sb: ^Sandbox, table: Material_Table, y, x0, x1: i32) -> (changed: bool) {
	base := sandbox_index(sb, 0, y)
	for x in x0 ..= x1 {
		i := base + int(x)
		if sb.moved[i] do continue

		if sb.lifetime[i] > 0 {
			sb.lifetime[i] -= 1
			sandbox_mark(sb, x, y)
			if sb.lifetime[i] == 0 {
				sandbox_put(sb, table, i, Cell(table.decays_to[sb.cells[i]]))
				sb.moved[i] = true
				changed = true
				continue
			}
		}

		work := table.work[sb.cells[i]]
		if work == {} do continue

		if .Sieves in work && sandbox_sift(sb, table, x, y) {
			changed = true
			continue
		}

		prof.count[.Reacts] += int(.Reacts in work)
		prof.count[.Fires] += int(.Burns in work)
		if .Reacts in work && sandbox_react(sb, table, x, y) {
			changed = true
			continue
		}

		if .Burns in work && sandbox_spread_fire(sb, table, x, y) {
			changed = true
			if .Flame in work {
				sb.moved[i] = true
			}
			sandbox_mark(sb, x, y)
		}
	}
	return changed
}

// One brush cell in BRUSH_WEAVE is woven too dense to pass. The weave
// is a hash of the world position, not a roll per tick, so a dense spot
// stays dense and the grain that lands on one stays lodged until fire
// or the digger frees it. Over a crop eleven cells tall, one in
// sixty-four a cell leaves about one grain in seven caught somewhere on
// the way down: mostly it flows through.
BRUSH_WEAVE :: 64
SANDBOX_SALT_SIFT :: 0x0000_0000_0000_0012

// Brush is porous. A powder or a liquid standing on a cell of brush
// mostly sifts straight down through it: the two trade places, so the
// grain trickles a cell a tick toward the ground and the stalk rides
// up over what gathers at its foot, the way a crop stands on a drift
// rather than under one. The brush cell is the side that does the
// work (`.Sieves`), because the falling side has already stopped: its
// own intent saw a wall below and nothing more.
sandbox_sift :: proc(sb: ^Sandbox, table: Material_Table, x, y: i32) -> bool {
	if y == 0 do return false
	above := sandbox_index(sb, x, y - 1)
	if sb.moved[above] do return false

	kind := table.kind[sb.cells[above]]
	if kind != .Powder && kind != .Liquid do return false

	if wang_hash(sb.seed, SANDBOX_SALT_SIFT, sb.origin_x + x, sb.origin_y + y) % BRUSH_WEAVE == 0 do return false
	return sandbox_swap(sb, x, y, x, y - 1)
}

sandbox_react :: proc(sb: ^Sandbox, table: Material_Table, x, y: i32) -> bool {
	sides := [4][2]i32{{1, 0}, {-1, 0}, {0, 1}, {0, -1}}

	index    := sandbox_index(sb, x, y)
	material := sb.cells[index]
	n        := len(table.materials)
	partners := table.partners[material]

	live:  [4]int // the sides that have a partner on them
	count: int
	for s, k in sides {
		nx, ny := x + s[0], y + s[1]
		if !sandbox_in_bounds(sb, nx, ny) do continue
		ni := sandbox_index(sb, nx, ny)
		// The bit says "these two never react", which is what almost
		// every neighbour is; reaction_at stays the authority after it.
		if partners >> (sb.cells[ni] & 63) & 1 == 0 do continue
		if sb.moved[ni] do continue
		if table.reaction_at[int(material) * n + int(sb.cells[ni])] < 0 do continue
		live[count] = k
		count += 1
	}
	if count == 0 do return false
	sandbox_mark(sb, x, y)

	s := sides[live[sandbox_chance(sb, x, y, .React_Side) % u32(count)]]
	ni := sandbox_index(sb, x + s[0], y + s[1])
	head := table.reaction_at[int(material) * n + int(sb.cells[ni])]

	// One roll for the pair, walked along the chain with a running floor.
	// See docs/alchemy.md, "A chain of rows".
	roll := sandbox_chance(sb, x, y, .React_Roll) & 255
	floor := u32(0)
	for at := head; at >= 0; {
		r := table.reactions[at]
		if roll < floor + u32(r.chance) {
			sandbox_put(sb, table, index, Cell(r.c))
			sandbox_put(sb, table, ni, Cell(r.d))
			sb.moved[index] = true
			sb.moved[ni] = true
			if r.c == table.sparkle do spark_add(sb, table, x, y)
			if r.d == table.sparkle do spark_add(sb, table, x + s[0], y + s[1])
			return true
		}
		floor += u32(r.chance)
		at = r.next
	}
	return false
}

sandbox_intent_cell :: proc(sb: ^Sandbox, y, x: i32) -> (dx, dy: i16) {
	r := &sb.rows
	i := int(x) + 1

	side := 1 - 2 * int(sandbox_side_bit(sb, x, y))
	near := i + side
	far  := i - side

	w     := r.here[i]
	above := r.above[i]
	kind  := r.kind[i]

	falls  := kind == .Powder || kind == .Liquid
	floats := kind == .Liquid
	climbs := kind == .Riser

	switch {
	case floats && sandbox_heavier(w, above):
		return 0, -1

	case falls && sandbox_sinks(w, r.below[i]):
		return 0, 1
	case falls && sandbox_sinks(w, r.below[near]):
		return i16(side), 1
	case falls && sandbox_sinks(w, r.below[far]):
		return i16(-side), 1

	case climbs && sandbox_rises(w, r.above[i]):
		return 0, -1
	case climbs && sandbox_rises(w, r.above[near]):
		return i16(side), -1
	case climbs && sandbox_rises(w, r.above[far]):
		return i16(-side), -1

	case floats && sandbox_spreads(w, r.here[near], r.below[near], above, r.above[near]):
		return i16(side), 0
	case floats && sandbox_spreads(w, r.here[far], r.below[far], above, r.above[far]):
		return i16(-side), 0

	case climbs && r.here[near] == CELL_AIR:
		return i16(side), 0
	}
	return 0, 0
}

sandbox_apply_row :: proc(sb: ^Sandbox, table: Material_Table, y, x0, x1: i32) {
	left_first := (sb.tick & 1) == 0
	for k in 0 ..= x1 - x0 {
		x := left_first ? x0 + k : x1 - k
		dx := i32(sb.rows.dx[x])
		dy := i32(sb.rows.dy[x])
		if dx == 0 && dy == 0 do continue
		sandbox_slide(sb, table, x, y, dx, dy)
	}
}

sandbox_slide :: proc(sb: ^Sandbox, table: Material_Table, x, y, dx, dy: i32) {
	if !sandbox_swap(sb, x, y, x + dx, y + dy) {
		sandbox_mark(sb, x, y)
		return
	}
	cx, cy := x + dx, y + dy
	if dy < 0 || (dx != 0 && dy != 0) do return

	w     := table.weight[sb.cells[sandbox_index(sb, cx, cy)]]
	speed := i32(table.materials[sb.cells[sandbox_index(sb, cx, cy)]].fall_speed)

	for _ in 1 ..< speed {
		nx, ny := cx + dx, cy + dy
		ok: bool
		if dy > 0 {
			ok = sandbox_sinks(w, sandbox_weight_at(sb, table, nx, ny))
		} else {
			ok = sandbox_spreads(
				w,
				sandbox_weight_at(sb, table, nx, ny),
				sandbox_weight_at(sb, table, nx, ny + 1),
				sandbox_weight_at(sb, table, cx, cy - 1),
				sandbox_weight_at(sb, table, nx, ny - 1),
			)
		}
		if !ok do break
		if !sandbox_swap(sb, cx, cy, nx, ny) do break
		cx, cy = nx, ny
	}
}

sandbox_swap :: proc(sb: ^Sandbox, sx, sy, dx, dy: i32) -> bool {
	if !sandbox_in_bounds(sb, dx, dy) do return false
	to := sandbox_index(sb, dx, dy)
	if sb.moved[to] do return false
	from := sandbox_index(sb, sx, sy)

	prof.count[.Swaps] += 1
	sb.cells[from], sb.cells[to] = sb.cells[to], sb.cells[from]
	sb.lifetime[from], sb.lifetime[to] = sb.lifetime[to], sb.lifetime[from]
	sb.moved[from] = true
	sb.moved[to] = true
	// The two cells are neighbours, so one box covers both marks.
	sandbox_mark_box(sb, min(sx, dx)-1, min(sy, dy)-1, max(sx, dx)+1, max(sy, dy)+1)
	return true
}
