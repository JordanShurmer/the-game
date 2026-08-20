package game

import "core:mem"

/*
One tick of the sandbox.

THE SHAPE OF THE OLD STEP, AND WHY IT CHANGED

The old step walked one cell at a time and settled everything about
that cell before it looked at the next one: a 32 byte Material load, a
chain of early returns, and a running random generator drawn from a
different number of times depending on which branch it took. Nothing
in that shape can be done to two cells at once, because the answer for
one cell depends on work already done for the cell beside it.

This step is a row at a time, in four passes, and no pass carries an
answer from one cell to the next:

	LOAD    turns the row of material ids, and the rows above and
	        below it, into weights and kinds. This is the only place
	        the step reads the material table.

	HOT     is everything that is not a move: a lifetime running out,
	        a reaction with a neighbour, fire spreading along fuel.
	        Almost no cell needs any of it, and two comparisons find
	        the ones that do.

	INTENT  compares the three rows and writes, for each cell, the one
	        step it wants to take. It reads only, so it is a fixed
	        list of comparisons repeated across the row.

	APPLY   walks the cells that want to move and moves them.

INTENT is where the tick is spent, because it is the pass that has to
look at every cell, and it is the pass this shape exists for.
sandbox_step_simd.odin is the same pass in vectors, and a test holds
the two to the same answer.

WEIGHT IS THE WHOLE MOVE RULE

Air weighs nothing and a wall weighs everything (src/cell.odin), so
"can this cell go there" is one comparison between two u16. Beyond the
edge of the sandbox is a wall and a cell that already moved this tick
is a wall, so the comparison needs no bounds test and no second flag.

The scan still runs from the bottom row up, so a cell that falls does
not fall again in the same tick, and a cell that moves is a wall for
the rest of the tick, so every cell moves at most once.
*/

// ------------------------------------------------------------
// The move rules, as comparisons between two weights
// ------------------------------------------------------------

// A cell sinks into anything lighter than itself. Air is lightest, so
// this covers falling into empty space; a wall is heaviest, so it
// covers refusing to enter a solid.
sandbox_sinks :: #force_inline proc "contextless" (src, dst: u16) -> bool {
	return dst < src
}

// A cell is under something it can change places with when that thing
// is heavier than it and is not a wall.
sandbox_heavier :: #force_inline proc "contextless" (src, dst: u16) -> bool {
	return dst > src && dst != CELL_WALL
}

// A cell rises into empty space, or changes places with anything
// heavier. This is how smoke climbs through air and how oil comes up
// through water.
sandbox_rises :: #force_inline proc "contextless" (src, dst: u16) -> bool {
	return dst == CELL_AIR || sandbox_heavier(src, dst)
}

/*
Whether a liquid gains anything by taking one step to the side.

A liquid flows for two reasons: the floor falls away on that side, or
something at least as heavy as itself rests on top and presses it out.
A cell with neither reason holds still, which is what stops a settled
pool swapping left and right for ever.

A wall on top presses nothing. It is the roof of the cave the pool is
in, and a pool that ran out from under its own roof would never
settle.

A hole with a fluid over it is left alone, because that fluid is about
to fall into it. Without this rule the pool never packs: the scan
reaches a row before the row above it, a cell takes the hole beside it
and leaves a hole where it was, and the cell that was going to drop
into the first hole is refused. The holes then walk from side to side
for ever and the pool keeps every one of them.
*/
sandbox_spreads :: #force_inline proc "contextless" (self, side, below_side, above, above_side: u16) -> bool {
	room      := side == CELL_AIR
	unclaimed := above_side == CELL_AIR || above_side == CELL_WALL
	downhill  := below_side == CELL_AIR
	pressed   := above >= self && above != CELL_WALL
	return room && unclaimed && (downhill || pressed)
}

/*
The weight of one cell, with the two rules that let every comparison
above skip its bounds test: beyond the edge of the sandbox is a wall,
and a cell that already moved this tick is a wall.

This is the only cell read in the step that goes through the material
table, and the LOAD pass is this proc across a row.
*/
sandbox_weight_at :: #force_inline proc(sb: ^Sandbox, table: Material_Table, x, y: i32) -> u16 {
	if !sandbox_in_bounds(sb, x, y) do return CELL_WALL
	i := sandbox_index(sb, x, y)
	if sb.moved[i] do return CELL_WALL
	return table.weight[sb.cells[i]]
}

// ------------------------------------------------------------
// The tick
// ------------------------------------------------------------

/*
Run one tick of the simulation.

Only the dirty rectangles are scanned; a chunk with nothing dirty in
it costs nothing. See docs/physics.md step 3.
*/
sandbox_step :: proc(sb: ^Sandbox, table: Material_Table) {
	// Two sets, not one. `dirty` is what this scan reads; `next_dirty`
	// is what sandbox_mark builds while this tick runs, and what a
	// command already built between the last tick and this one.
	// Swapping before any cell is touched is what stops a mark made
	// mid-scan from dragging this tick's own work past where the scan
	// already is (rule 1): a single falling grain must not turn into a
	// scan that chases it down the sandbox.
	sb.dirty, sb.next_dirty = sb.next_dirty, sb.dirty
	for &r in sb.next_dirty do r = SANDBOX_RECT_EMPTY

	// Clear `moved` only under this tick's dirty rectangles, and clear
	// all of it before any cell is stepped. A cell reads `moved` on
	// neighbours the row scan below has not reached yet, so every
	// dirty cell must read false before the scan starts.
	for r in sb.dirty {
		if r.min_x > r.max_x do continue
		width := int(r.max_x - r.min_x + 1)
		for y in r.min_y ..= r.max_y {
			row_start := sandbox_index(sb, r.min_x, y)
			mem.zero_slice(sb.moved[row_start:row_start + width])
		}
	}

	for y := sb.height - 1; y >= 0; y -= 1 {
		cy := y / SANDBOX_CHUNK
		chunk_row := sb.dirty[cy * sb.chunks_x:(cy + 1) * sb.chunks_x]
		for r in chunk_row {
			if y < r.min_y || y > r.max_y do continue // nothing on this row
			sandbox_step_row(sb, table, y, r.min_x, r.max_x)
		}
	}

	sb.tick += 1
}

/*
The four passes, over the cells x0 to x1 of one row.

Two of the four are skipped outright most of the time, and LOAD is
what says so: it reads the row once and reports whether any cell in it
has a lifetime or a reaction, so a row of rock and air pays nothing for
the hot pass. INTENT reports the same about movement, so a row that
has settled pays nothing for the apply pass either.
*/
sandbox_step_row :: proc(sb: ^Sandbox, table: Material_Table, y, x0, x1: i32) {
	if sandbox_load_row(sb, table, y, x0, x1) {
		if sandbox_hot_row(sb, table, y, x0, x1) {
			// The hot pass wrote cells, so what LOAD read is out of
			// date. This costs a second read of a row now and then; it
			// saves a flag on every cell that would say whether the
			// first read is still good.
			sandbox_load_row(sb, table, y, x0, x1)
		}
	}
	if sandbox_intent_row(sb, y, x0, x1) {
		sandbox_apply_row(sb, table, y, x0, x1)
	}
}

// ------------------------------------------------------------
// LOAD
// ------------------------------------------------------------

/*
Read three rows of cells into the numbers the passes below compare.

The rows are indexed by world x plus one, so the cell before the row
and the cell after it are real entries holding CELL_WALL rather than a
bounds test in the inner loop. sandbox_make writes those two entries
once and nothing ever writes them again.

A cell that already moved this tick is a wall, and a wall never moves,
so it needs no kind of its own. `wall` below is all ones for such a
cell and nothing for every other one, which turns both of those rules
into one bitwise operation apiece and leaves no branch in the loop.

The result reports whether any cell of this row needs the hot pass.
The loop has the material in hand anyway, so the answer is free, and
it saves a second walk of the row for the rows that have no lifetime
and no reaction in them, which is most of them.
*/
sandbox_load_row :: proc(sb: ^Sandbox, table: Material_Table, y, x0, x1: i32) -> (hot: bool) {
	// One cell either side of the span, because a cell looks at its
	// neighbours. That one cell is also the whole margin the vector
	// pass reads past its last lane, so these two clamps and
	// SANDBOX_LANES have to be read together.
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

// One row of weights. Beyond the top and the bottom of the sandbox is
// a wall, the same as beyond its sides.
sandbox_load_weights :: proc(sb: ^Sandbox, table: Material_Table, out: []u16, y, lo, hi: i32) {
	if y < 0 || y >= sb.height {
		for x in lo ..= hi do out[x + 1] = CELL_WALL
		return
	}
	base := sandbox_index(sb, 0, y)
	for x in lo ..= hi {
		i := base + int(x)
		out[x + 1] = table.weight[sb.cells[i]] | (u16(0) - u16(sb.moved[i]))
	}
}

// ------------------------------------------------------------
// HOT
// ------------------------------------------------------------

/*
Everything that is not a move: a lifetime running out, a reaction with
a neighbour, and fire spreading along fuel.

Almost no cell needs any of this. A lifetime above zero and a work set
that is not empty are the two comparisons that find the ones that do.

The result reports whether any cell changed, because a cell that
changed makes what LOAD read out of date.
*/
sandbox_hot_row :: proc(sb: ^Sandbox, table: Material_Table, y, x0, x1: i32) -> (changed: bool) {
	base := sandbox_index(sb, 0, y)
	for x in x0 ..= x1 {
		i := base + int(x)
		if sb.moved[i] do continue

		if sb.lifetime[i] > 0 {
			sb.lifetime[i] -= 1
			// A cell counting down does not move and touches no
			// neighbour, so nothing else would keep its chunk awake.
			// Without this the countdown would only finish by chance,
			// and fire would freeze in mid air instead of turning to
			// smoke on schedule (docs/physics.md step 3, rule 4).
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

		if .Reacts in work && sandbox_react(sb, table, x, y) {
			changed = true
			continue
		}

		if .Burns in work && sandbox_spread_fire(sb, table, x, y) {
			changed = true
			// A flame beside fuel holds still, so the fire runs the
			// length of a trail of oil instead of climbing away from
			// it on the first tick. Lava burns what it touches too and
			// is not a flame, so it keeps flowing.
			if .Flame in work {
				sb.moved[i] = true
			}
			// A flame that holds still beside fuel still has work next
			// tick: the fuel may catch a tick later, and the flame's
			// own lifetime is still running down.
			sandbox_mark(sb, x, y)
		}
	}
	return changed
}

/*
React with one neighbour.

One roll a cell a tick, and it is rolled against a side that has a
partner on it. Rolling against a side with nothing on it would only
make a certain reaction wait for luck it does not need: a flame and
the water above it change places on the tick they meet, so a probe
that lands on one of the three empty sides is the only chance the pair
ever gets. See docs/physics.md, "The reaction table".

The four sides are walked anyway, because whether ANY side could react
decides whether this cell is worth a look next tick. Without that a
cell falls asleep with a live partner beside it, and a pool of acid
stops eating the rock it is still touching (docs/physics.md step 3,
rule 4).

The result reports whether this cell changed.
*/
sandbox_react :: proc(sb: ^Sandbox, table: Material_Table, x, y: i32) -> bool {
	sides := [4][2]i32{{1, 0}, {-1, 0}, {0, 1}, {0, -1}}

	index    := sandbox_index(sb, x, y)
	material := sb.cells[index]
	n        := len(table.materials)

	live:  [4]int // the sides that have a partner on them
	count: int
	for s, k in sides {
		nx, ny := x + s[0], y + s[1]
		if !sandbox_in_bounds(sb, nx, ny) do continue
		// A neighbour that already changed this tick is not a safe
		// partner: reacting with it now would overwrite what just
		// wrote it there.
		ni := sandbox_index(sb, nx, ny)
		if sb.moved[ni] do continue
		if table.reaction_at[int(material) * n + int(sb.cells[ni])] < 0 do continue
		live[count] = k
		count += 1
	}
	if count == 0 do return false
	sandbox_mark(sb, x, y)

	s := sides[live[sandbox_chance(sb, x, y, .React_Side) % u32(count)]]
	ni := sandbox_index(sb, x + s[0], y + s[1])
	r  := table.reactions[table.reaction_at[int(material) * n + int(sb.cells[ni])]]
	if sandbox_chance(sb, x, y, .React_Roll) & 255 >= u32(r.chance) do return false

	sandbox_put(sb, table, index, Cell(r.c))
	sandbox_put(sb, table, ni, Cell(r.d))
	sb.moved[index] = true
	sb.moved[ni] = true
	return true
}

// ------------------------------------------------------------
// INTENT
// ------------------------------------------------------------

/*
The one step each cell of the row wants to take, as an offset.

sandbox_intent_row in sandbox_step_simd.odin does this a vector of
cells at a time, and is what actually runs. This is the same rules a
cell at a time: it is what that pass is read against, what a test
holds it to, and what runs on the few cells at the end of a row that
do not fill a vector.

Nothing here writes a cell, so no answer depends on any other answer.
The questions below are asked of every cell in the row, and the first
one the cell is allowed to use and that holds decides where it goes.
That list is the whole movement model of the game, and the numbers on
it are the numbers sandbox_intent_row carries on the same ten
questions.

`near` is the side the cell tries first and `far` is the other one.
Which is which comes from a hash of the place and the tick, so a cell
gets the same side however the scan reaches it.
*/
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
	// A liquid with something heavier resting on it changes places
	// with it. Without this rule the scan order alone decides which of
	// the pair moves, and two liquids never layer.
	case floats && sandbox_heavier(w, above): // 1
		return 0, -1

	case falls && sandbox_sinks(w, r.below[i]): // 2
		return 0, 1
	case falls && sandbox_sinks(w, r.below[near]): // 3
		return i16(side), 1
	case falls && sandbox_sinks(w, r.below[far]): // 4
		return i16(-side), 1

	case climbs && sandbox_rises(w, r.above[i]): // 5
		return 0, -1
	case climbs && sandbox_rises(w, r.above[near]): // 6
		return i16(side), -1
	case climbs && sandbox_rises(w, r.above[far]): // 7
		return i16(-side), -1

	case floats && sandbox_spreads(w, r.here[near], r.below[near], above, r.above[near]): // 8
		return i16(side), 0
	case floats && sandbox_spreads(w, r.here[far], r.below[far], above, r.above[far]): // 9
		return i16(-side), 0

	// A gas under a ceiling gathers along it rather than sitting in
	// one column.
	case climbs && r.here[near] == CELL_AIR: // 10
		return i16(side), 0
	}
	return 0, 0
}

// ------------------------------------------------------------
// APPLY
// ------------------------------------------------------------

/*
Move the cells that want to move.

INTENT settled every rule, so this pass only has to find out whether
the place a cell wants is still free. It can have been taken since:
two cells of a row can want the same cell below them, and the one this
pass reaches first gets it. The direction the pass walks the row flips
with the tick, so neither end of the row wins for ever.
*/
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

/*
Move one cell, and keep it going while the way stays clear.

fall_speed is how many cells a material crosses in one tick, which is
what makes water run and lava crawl. Only a straight move repeats: a
diagonal is a step around an obstacle, and one of those a tick is
enough. Nothing that climbs repeats either, because every gas and
flame in the table crosses one cell a tick.
*/
sandbox_slide :: proc(sb: ^Sandbox, table: Material_Table, x, y, dx, dy: i32) {
	if !sandbox_swap(sb, x, y, x + dx, y + dy) {
		// The place this cell wanted was taken by another cell of the
		// same row. The work is not done, so the cell stays dirty and
		// tries again next tick. Without this a pool freezes with the
		// holes it happened to hold on the one tick when every cell in
		// it was refused, and never packs.
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

/*
Change two cells over.

Both are then walls for the rest of the tick, so every cell moves at
most once and nothing else can enter the hole this one left.
*/
sandbox_swap :: proc(sb: ^Sandbox, sx, sy, dx, dy: i32) -> bool {
	if !sandbox_in_bounds(sb, dx, dy) do return false
	to := sandbox_index(sb, dx, dy)
	if sb.moved[to] do return false
	from := sandbox_index(sb, sx, sy)

	sb.cells[from], sb.cells[to] = sb.cells[to], sb.cells[from]
	sb.lifetime[from], sb.lifetime[to] = sb.lifetime[to], sb.lifetime[from]
	sb.moved[from] = true
	sb.moved[to] = true
	// The swap does not go through sandbox_put, so it marks both sides
	// itself. See sandbox_mark.
	sandbox_mark(sb, sx, sy)
	sandbox_mark(sb, dx, dy)
	return true
}
