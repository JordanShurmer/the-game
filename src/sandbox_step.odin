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

// A fluid may step aside onto an empty cell, if nothing is about to drop
// into that cell first. "Behind" is the row the fluid came from: over a
// liquid, under a gas. Fluid behind the target is about to take it, so
// stepping aside there would only walk the hole along the row and the
// pool would never pack. See docs/physics.md, "The packing rule".
//
// Whether the step is worth taking is not asked here. That is the whole
// question a fluid has, and sandbox_flow answers it by looking along the
// row.
sandbox_spreads :: #force_inline proc "contextless" (side, behind_side: u16) -> bool {
	room      := side == CELL_AIR
	unclaimed := behind_side == CELL_AIR || behind_side == CELL_WALL
	return room && unclaimed
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

	case floats && sandbox_spreads(r.here[near], r.above[near]):
		return i16(side), 0
	case floats && sandbox_spreads(r.here[far], r.above[far]):
		return i16(-side), 0

	case climbs && sandbox_spreads(r.here[near], r.below[near]):
		return i16(side), 0
	case climbs && sandbox_spreads(r.here[far], r.below[far]):
		return i16(-side), 0
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

		// A fluid going sideways is not taking a step, it is looking for
		// a way on, and how far it looks is what makes a pool level.
		kind := sb.rows.kind[x + 1]
		if dy == 0 && (kind == .Liquid || kind == .Riser) {
			sandbox_flow(sb, table, x, y, dx, kind == .Liquid ? 1 : -1)
			continue
		}
		sandbox_slide(sb, table, x, y, dx, dy)
	}
}

// The way on, and how far a fluid looks for it.
//
// A liquid that cannot fall is not finished: somewhere along the row it
// lies in there may be a cell it can fall out of, and water finds it. So
// a stopped fluid looks along its own row -- a liquid for a cell it can
// sink from, a gas for one it can climb from -- as far as the material's
// `spread` says, and goes to the first one it finds. The cells between
// are empty and of one kind, so going the whole way is the same picture
// as walking it, and the walk would only leave a cell standing in the
// row for the fluid behind to trip over.
//
// This one procedure is what levels a pool. Without it a liquid can only
// step onto the cell beside it, a one-cell step down in its own surface
// is a cell it will not step onto, and a staircase of one-cell steps is a
// shape it holds for ever: measured, a column of water on a flat floor
// froze as a 45 degree wedge within 50 ticks and had not moved at tick
// 12000. With it, the reach is the flatness -- what settles is a surface
// that falls about one cell every `spread` cells -- so water (64) reads
// level and lava (3) keeps the slope of a lava flow.
//
// `ahead` is the way the fluid wants to go: down (+1) for a liquid, up
// (-1) for a gas. Nothing else about the two differs, so one procedure
// serves both.
sandbox_flow :: proc(sb: ^Sandbox, table: Material_Table, x, y, side, ahead: i32) -> bool {
	m := sb.cells[sandbox_index(sb, x, y)]
	w := table.weight[m]
	reach := i32(table.materials[m].spread)

	for s in ([2]i32{side, -side}) {
		for k in i32(1) ..= reach {
			nx := x + s * k
			if !sandbox_in_bounds(sb, nx, y) do break
			ahead_of := sandbox_weight_at(sb, table, nx, y + ahead)
			behind   := sandbox_weight_at(sb, table, nx, y - ahead)
			if !sandbox_spreads(sandbox_weight_at(sb, table, nx, y), behind) do break

			if !(ahead > 0 ? sandbox_sinks(w, ahead_of) : sandbox_rises(w, ahead_of)) do continue

			// It has found the way on. A refused swap -- the cell it
			// wants has already moved this tick -- still has to leave
			// the cell awake, or the chunk sleeps with the fluid in
			// mid-flow.
			if !sandbox_swap(sb, x, y, nx, y) {
				sandbox_mark(sb, x, y)
				return false
			}
			sandbox_wake_reach(sb, x, y, k)
			return true
		}
	}

	// It found nothing this tick and stays awake to look again. What
	// would let it on is further off than a swap wakes, and the far end
	// of its reach can be changed by water it cannot see -- so a fluid
	// with somewhere to step and nowhere to go keeps watch itself.
	//
	// This is only ever reached by a fluid with an empty cell beside it
	// at its own level, which a packed pool has nowhere but at its two
	// ends: the cells inside one are stopped by their own kind and never
	// get here, so a settled pond still wakes no chunk at all. What it
	// costs is a handful of cells at the open edge of a body of water,
	// and what it buys is that a pond finds its level rather than
	// leaving a shelf of it stranded up the bank.
	sandbox_mark(sb, x, y)
	return false
}

// The band a fluid that just moved has to wake behind it.
//
// A swap wakes the cells it touches and no more, which is enough while
// matter moves one cell at a time. A fluid reads along its row until
// something stops it, so a cell that saw the way on `k` cells off was
// itself in view of any fluid up to `k` cells the other way, along the
// same open run and in the row over and the row under. Wake that band,
// or a flow leaves its own tail asleep and the pool stops half way.
//
// The band is as wide as the look that earned it, so it costs what the
// flow costs: nothing where nothing moved, one cell either side in a
// packed pool, and the whole reach only where a fluid is running the
// length of a row.
sandbox_wake_reach :: proc(sb: ^Sandbox, x, y, k: i32) {
	sandbox_mark_box(sb, x - k - 1, y - 1, x + k + 1, y + 1)
}

sandbox_slide :: proc(sb: ^Sandbox, table: Material_Table, x, y, dx, dy: i32) {
	if !sandbox_swap(sb, x, y, x + dx, y + dy) {
		sandbox_mark(sb, x, y)
		return
	}
	// Only a straight fall carries on: sideways is sandbox_flow's, and a
	// diagonal step has already found its floor.
	cx, cy := x + dx, y + dy
	if dy <= 0 || dx != 0 do return

	w     := table.weight[sb.cells[sandbox_index(sb, cx, cy)]]
	speed := i32(table.materials[sb.cells[sandbox_index(sb, cx, cy)]].fall_speed)

	for _ in 1 ..< speed {
		nx, ny := cx, cy + 1
		if !sandbox_sinks(w, sandbox_weight_at(sb, table, nx, ny)) do break
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
