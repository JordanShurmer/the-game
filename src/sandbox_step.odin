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

// Stepping aside onto an empty cell, where nothing is about to drop into
// that cell first. "Behind" is the row the fluid came from: over a
// liquid, under a gas. Fluid behind the target is about to take it, so
// stepping aside there would only walk the hole along the row and the
// pool would never pack. See docs/physics.md, "The packing rule".
sandbox_unclaimed :: #force_inline proc "contextless" (side, behind_side: u16) -> bool {
	return side == CELL_AIR && (behind_side == CELL_AIR || behind_side == CELL_WALL)
}

// What a fluid may move through, sideways. It displaces anything lighter
// than itself that is the same sort of fluid, and it steps into an empty
// cell that nothing is about to fall into. It never goes through a
// powder: a pool of quicksilver beside a sand bank tunnels straight
// through the bank without that, because sand is lighter than it.
//
// The packing rule is only asked of an empty cell. Displacing another
// liquid does not leave a hole to walk -- the two exchange -- so there
// is nothing there for it to guard.
//
// Whether the step is worth taking is not asked here. That is the whole
// question a fluid has, and sandbox_flow answers it by looking along the
// row.
sandbox_shifts :: #force_inline proc "contextless" (self, side, behind_side: u16, side_kind: Cell_Kind) -> bool {
	return sandbox_sinks(self, side) && (sandbox_unclaimed(side, behind_side) || side_kind == .Liquid)
}

sandbox_lifts :: #force_inline proc "contextless" (self, side, behind_side: u16, side_kind: Cell_Kind) -> bool {
	return sandbox_rises(self, side) && (sandbox_unclaimed(side, behind_side) || side_kind == .Riser)
}

sandbox_kind_at :: #force_inline proc(sb: ^Sandbox, table: Material_Table, x, y: i32) -> Cell_Kind {
	if !sandbox_in_bounds(sb, x, y) do return .Still
	i := sandbox_index(sb, x, y)
	if sb.moved[i] do return .Still
	return table.kind[sb.cells[i]]
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
		prof.count[.Chunks_Awake] += 1
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

	hot, wet := sandbox_load_row(sb, table, y, x0, x1)
	if hot {
		prof.count[.Hot_Rows] += 1
		if sandbox_hot_row(sb, table, y, x0, x1) {
			_, wet = sandbox_load_row(sb, table, y, x0, x1)
		}
	}
	// The head is a liquid's alone, so a dry row -- which is most of the
	// world -- never pays for it. A row with no liquid in it also has no
	// head in it to go stale, because the pass writes zero wherever the
	// cell is not a liquid.
	if wet do sandbox_head_row(sb, table, y, x0, x1)
	if sandbox_intent_row(sb, y, x0, x1) {
		prof.count[.Moving_Rows] += 1
		sandbox_apply_row(sb, table, y, x0, x1)
	}
}

sandbox_load_row :: proc(sb: ^Sandbox, table: Material_Table, y, x0, x1: i32) -> (hot, wet: bool) {
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
		r.head[x + 1] = u16(sb.head[i]) &~ wall
		hot ||= (table.work[c] != {} || sb.lifetime[i] > 0) && !sb.moved[i]
		wet ||= table.kind[c] == .Liquid
	}
	return hot, wet
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

	case floats && sandbox_shifts(w, r.here[near], r.above[near], r.kind[near]):
		return i16(side), 0
	case floats && sandbox_shifts(w, r.here[far], r.above[far], r.kind[far]):
		return i16(-side), 0

	case climbs && sandbox_lifts(w, r.here[near], r.below[near], r.kind[near]):
		return i16(side), 0
	case climbs && sandbox_lifts(w, r.here[far], r.below[far], r.kind[far]):
		return i16(-side), 0

	case floats && sandbox_presses(r.head[i], w, r.below[i]):
		return 0, -1
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
		// Two arms send a liquid up: the rise rule, which wants a
		// heavier liquid over it, and the press, which does not. One
		// test tells them apart.
		if kind == .Liquid && dy < 0 && !sandbox_heavier(sb.rows.here[x + 1], sb.rows.above[x + 1]) {
			sandbox_press(sb, table, x, y)
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
	reach := i32(table.spread[m])

	open_row := false
	for s in ([2]i32{side, -side}) {
		for k in i32(1) ..= reach {
			nx := x + s * k
			if !sandbox_in_bounds(sb, nx, y) do break
			at       := sandbox_weight_at(sb, table, nx, y)
			at_kind  := sandbox_kind_at(sb, table, nx, y)
			ahead_of := sandbox_weight_at(sb, table, nx, y + ahead)
			behind   := sandbox_weight_at(sb, table, nx, y - ahead)
			// May it pass through this cell? Which is not the same
			// question as whether this cell is the way on.
			open := ahead > 0 ? sandbox_shifts(w, at, behind, at_kind) : sandbox_lifts(w, at, behind, at_kind)
			if !open do break
			open_row ||= at == CELL_AIR

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

	// It found nothing this tick, and whether it keeps watch depends on
	// what it was looking across. Along open row, what would let it on
	// lies further off than a swap wakes, and the far end of its reach
	// can be changed by water it never touched -- so it marks itself and
	// looks again. Looking only through its own kind, what would let it
	// on is a neighbour, and a neighbour that moves wakes it: the news
	// walks a cell a tick and costs nothing to wait for.
	//
	// A packed pool has open row nowhere but at its two ends, so a
	// settled pond still wakes no chunk at all. What this costs is a
	// handful of cells at the open edge of a body of water, and what it
	// buys is that a pond finds its level rather than leaving a shelf of
	// it stranded up the bank.
	if open_row do sandbox_mark(sb, x, y)
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

// How deep a body of liquid stands over a cell, and whether more of it
// stands there than the cell's own column explains.
//
// The low seven bits are the head: one more than the cell over this one,
// where that cell is the same liquid, and otherwise nothing. That alone
// is a column count, and a column count knows nothing about the water
// round the corner. So the row term takes the greatest head of a
// same-liquid neighbour on this row as well, which is how a head walks
// along a passage and out of the far end of it, and how the water at
// the foot of one shaft learns that a taller shaft stands on the same
// floor.
//
// Bit 7 says the row term won: there is head here that this column
// cannot account for, and something must give. That bit is the whole
// gate on the press, and it is inherited down a column, because at the
// foot of a short shaft the column term is one greater a row and would
// otherwise swallow the very difference it is carrying.
//
// **The pass marks nothing, ever.** A head is one number for a whole
// body of water, so a cell that moves anywhere in a lake changes it
// everywhere, and a pass that woke what it changed woke the lake:
// measured, Lake went from 7.3 ms a tick to 39.6. Instead the field
// travels only where matter is already awake, which is the only place
// anything can act on it, and a settled pool's field is frozen because
// nothing in it changed.
SANDBOX_HEAD_MAX   :: 127
SANDBOX_HEAD_PRESS :: 0x80

// The whole field at once, for a sandbox that has just been filled from
// the world. The step relaxes the field only on rows that are awake, and
// water drawn at rest sleeps on its second tick -- long before a head has
// travelled the depth of it -- so a pond that is authored full would
// never learn it stands over anything. This gives it the field it has
// earned before the first tick: one pass down, both ways along every
// row, which is all the relaxation a body needs when nothing has moved
// yet.
sandbox_head_fill :: proc(sb: ^Sandbox, table: Material_Table) {
	for y in i32(0) ..< sb.height {
		sandbox_head_sweep(sb, table, y, 0, sb.width - 1, true)
		sandbox_head_sweep(sb, table, y, 0, sb.width - 1, false)
	}
}

sandbox_head_row :: proc(sb: ^Sandbox, table: Material_Table, y, x0, x1: i32) {
	sandbox_head_sweep(sb, table, y, x0, x1, sb.tick & 1 == 0)
}

// One sweep of the relaxation, left to right or right to left. The row
// term is a running maximum, so it only travels the way the sweep goes;
// the step alternates the direction by tick so a head reaches both ends
// of a passage, and the fill sweeps both ways at once so a world that
// opens with water already in it starts with the field it has earned.
sandbox_head_sweep :: proc(sb: ^Sandbox, table: Material_Table, y, x0, x1: i32, rightward: bool) {
	base := sandbox_index(sb, 0, y)
	first, last, step := x0, x1 + 1, i32(1)
	if !rightward do first, last, step = x1, x0 - 1, -1

	for x := first; x != last; x += step {
		i := base + int(x)
		c := sb.cells[i]
		out := u8(0)
		if table.kind[c] == .Liquid {
			column, carried := u8(0), u8(0)
			if y > 0 {
				j := i - int(sb.width)
				if sb.cells[j] == c {
					h := sb.head[j] & SANDBOX_HEAD_MAX
					column = h < SANDBOX_HEAD_MAX ? h + 1 : SANDBOX_HEAD_MAX
					carried = sb.head[j] & SANDBOX_HEAD_PRESS
				}
			}
			head := column
			if x > 0 && sb.cells[i - 1] == c do head = max(head, sb.head[i - 1] & SANDBOX_HEAD_MAX)
			if x < sb.width - 1 && sb.cells[i + 1] == c do head = max(head, sb.head[i + 1] & SANDBOX_HEAD_MAX)
			out = head | (head > column ? SANDBOX_HEAD_PRESS : carried)
		}
		sb.head[i] = out
		sb.rows.head[x + 1] = u16(out) &~ (u16(0) - u16(sb.moved[i]))
	}
}

// A liquid presses when a deeper body than its own column stands over it
// and it rests on something that is not its own kind. The second test is
// what makes a column ask once a tick rather than once for every cell in
// it: only the foot of a column ever asks.
sandbox_presses :: #force_inline proc "contextless" (head, self, under: u16) -> bool {
	return head & SANDBOX_HEAD_PRESS != 0 && under != self
}

// Carrying a head round a corner and up a shaft.
//
// The cell that presses does not move. It looks along the row it stands
// in, through its own liquid, for a column of that liquid standing two
// clear cells over the top of its own, and moves the top cell of that
// column onto the top of this one. Every cell between the two is the
// same liquid, so taking the far end is the same picture in the grid as
// shifting the whole run one cell along, and it leaves no hole anywhere
// -- which is why this and not a cell climbing into the air over its own
// head, which foams: the cell rises, the cell under it falls back into
// the hole, and the pair swap for ever.
//
// Two clear cells and not one. One press drops the far surface a cell
// and lifts this one a cell, so a difference of one would cross over and
// press straight back: measured, a pool locked into a permanent 2,3,2,3
// and never slept. It is the same shape as the rise rule's strict test.
//
// It marks nothing when it finds nothing, which is what leaves a settled
// pool asleep -- and in a level pool nothing sets bit 7 at all, so this
// is never even called.
sandbox_press :: proc(sb: ^Sandbox, table: Material_Table, x, y: i32) -> bool {
	m := sb.cells[sandbox_index(sb, x, y)]
	reach := i32(table.spread[m])

	// The top of this column, and the cell over it, which must be open.
	ys := y
	for _ in i32(0) ..< reach {
		ny := ys - 1
		if !sandbox_in_bounds(sb, x, ny) do return false
		if sb.cells[sandbox_index(sb, x, ny)] != m do break
		ys = ny
	}
	over := ys - 1
	if !sandbox_in_bounds(sb, x, over) do return false
	oi := sandbox_index(sb, x, over)
	if sb.cells[oi] != MATERIAL_AIR || sb.moved[oi] do return false

	side := 1 - 2 * i32(sandbox_side_bit(sb, x, y))
	for s in ([2]i32{side, -side}) {
		for k in i32(1) ..= reach {
			nx := x + s * k
			if !sandbox_in_bounds(sb, nx, y) do break
			if sb.cells[sandbox_index(sb, nx, y)] != m do break // the body ends here

			high := over - 1
			if !sandbox_in_bounds(sb, nx, high) do continue
			if sb.cells[sandbox_index(sb, nx, high)] != m do continue

			ts := high
			for _ in i32(0) ..< reach {
				ny := ts - 1
				if !sandbox_in_bounds(sb, nx, ny) do break
				if sb.cells[sandbox_index(sb, nx, ny)] != m do break
				ts = ny
			}
			if sb.moved[sandbox_index(sb, nx, ts)] do continue
			free := ts - 1
			if !sandbox_in_bounds(sb, nx, free) do continue
			if sb.cells[sandbox_index(sb, nx, free)] != MATERIAL_AIR do continue // under a lid

			if !sandbox_press_move(sb, nx, ts, x, over) do return false
			sandbox_wake_reach(sb, x, y, k)
			return true
		}
	}
	return false
}

// The press moves two cells that are not neighbours, so it wakes each
// end itself: sandbox_swap's one box would wake every chunk between them.
sandbox_press_move :: proc(sb: ^Sandbox, sx, sy, dx, dy: i32) -> bool {
	from := sandbox_index(sb, sx, sy)
	to   := sandbox_index(sb, dx, dy)
	if sb.moved[from] || sb.moved[to] do return false

	prof.count[.Swaps] += 1
	sb.cells[from], sb.cells[to] = sb.cells[to], sb.cells[from]
	sb.lifetime[from], sb.lifetime[to] = sb.lifetime[to], sb.lifetime[from]
	sb.moved[from] = true
	sb.moved[to] = true
	sandbox_mark(sb, sx, sy)
	sandbox_mark(sb, dx, dy)
	return true
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
	speed := i32(table.fall_speed[sb.cells[sandbox_index(sb, cx, cy)]])

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
