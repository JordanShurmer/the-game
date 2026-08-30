package game

import "base:intrinsics"
import "core:simd"
import "core:testing"

SANDBOX_LANES :: 16

@(private = "file") Weights :: #simd[SANDBOX_LANES]u16
@(private = "file") Steps   :: #simd[SANDBOX_LANES]i16

@(private = "file")
LANE :: Weights{0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15}

@(private = "file")
wide_sinks :: #force_inline proc "contextless" (src, dst: Weights) -> Weights {
	return simd.lanes_lt(dst, src)
}

@(private = "file")
wide_heavier :: #force_inline proc "contextless" (src, dst: Weights) -> Weights {
	return simd.lanes_gt(dst, src) & simd.lanes_ne(dst, Weights(CELL_WALL))
}

@(private = "file")
wide_rises :: #force_inline proc "contextless" (src, dst: Weights) -> Weights {
	return simd.lanes_eq(dst, Weights(CELL_AIR)) | wide_heavier(src, dst)
}

@(private = "file")
wide_spreads :: #force_inline proc "contextless" (side, behind_side: Weights) -> Weights {
	room      := simd.lanes_eq(side, Weights(CELL_AIR))
	unclaimed := simd.lanes_eq(behind_side, Weights(CELL_AIR)) | simd.lanes_eq(behind_side, Weights(CELL_WALL))
	return room & unclaimed
}

@(private = "file")
wide_presses :: #force_inline proc "contextless" (head, self, under: Weights) -> Weights {
	return simd.lanes_ne(head & Weights(u16(SANDBOX_HEAD_PRESS)), Weights(0)) &
	       simd.lanes_ne(under, self)
}

@(private = "file")
wide_side_bit :: #force_inline proc "contextless" (sb: ^Sandbox, x, y: i32) -> Weights {
	xs := Weights(u16(x)) + LANE
	h  := xs * Weights(0x2545)
	h += Weights(u16(y) * 0x9E3B + u16(sb.tick) * 0x85EB + sandbox_seed16(sb.seed))
	h ~= simd.shr(h, Weights(7))
	h *= Weights(0x2C1B)
	return simd.shr(h, Weights(15))
}

@(private = "file")
wide_at :: #force_inline proc "contextless" (row: []u16, i: int) -> Weights {
	return intrinsics.unaligned_load((^Weights)(&row[i]))
}

@(private = "file")
wide_sides :: #force_inline proc "contextless" (to_right: Weights, row: []u16, i: int) -> (near, far: Weights) {
	left  := wide_at(row, i - 1)
	right := wide_at(row, i + 1)
	return simd.select(to_right, right, left), simd.select(to_right, left, right)
}

@(private = "file")
wide_put :: #force_inline proc "contextless" (dx, dy: ^Steps, cond: Weights, tx, ty: Steps) {
	dx^ = simd.select(cond, tx, dx^)
	dy^ = simd.select(cond, ty, dy^)
}

sandbox_intent_row :: proc(sb: ^Sandbox, y, x0, x1: i32) -> (moving: bool) {
	r := &sb.rows
	kind_row := transmute([]u16)r.kind

	any: Steps
	x := x0
	for ; x + SANDBOX_LANES <= x1 + 1; x += SANDBOX_LANES {
		i := int(x) + 1

		w    := wide_at(r.here, i)
		kind := wide_at(kind_row, i)

		to_right  := simd.lanes_eq(wide_side_bit(sb, x, y), Weights(0))
		near_step := simd.select(to_right, Steps(1), Steps(-1))
		far_step  := simd.select(to_right, Steps(-1), Steps(1))

		here_near, here_far   := wide_sides(to_right, r.here, i)
		below_near, below_far := wide_sides(to_right, r.below, i)
		above_near, above_far := wide_sides(to_right, r.above, i)

		below := wide_at(r.below, i)
		above := wide_at(r.above, i)

		falls  := simd.lanes_eq(kind, Weights(u16(Cell_Kind.Powder))) |
		          simd.lanes_eq(kind, Weights(u16(Cell_Kind.Liquid)))
		floats := simd.lanes_eq(kind, Weights(u16(Cell_Kind.Liquid)))
		climbs := simd.lanes_eq(kind, Weights(u16(Cell_Kind.Riser)))

		head := wide_at(r.head, i)

		dx, dy: Steps
		wide_put(&dx, &dy, floats & wide_presses(head, w, below), 0, -1)
		wide_put(&dx, &dy, climbs & wide_spreads(here_far, below_far), far_step, 0)
		wide_put(&dx, &dy, climbs & wide_spreads(here_near, below_near), near_step, 0)
		wide_put(&dx, &dy, floats & wide_spreads(here_far, above_far), far_step, 0)
		wide_put(&dx, &dy, floats & wide_spreads(here_near, above_near), near_step, 0)
		wide_put(&dx, &dy, climbs & wide_rises(w, above_far), far_step, -1)
		wide_put(&dx, &dy, climbs & wide_rises(w, above_near), near_step, -1)
		wide_put(&dx, &dy, climbs & wide_rises(w, above), 0, -1)
		wide_put(&dx, &dy, falls & wide_sinks(w, below_far), far_step, 1)
		wide_put(&dx, &dy, falls & wide_sinks(w, below_near), near_step, 1)
		wide_put(&dx, &dy, falls & wide_sinks(w, below), 0, 1)
		wide_put(&dx, &dy, floats & wide_heavier(w, above), 0, -1)

		intrinsics.unaligned_store((^Steps)(&r.dx[x]), dx)
		intrinsics.unaligned_store((^Steps)(&r.dy[x]), dy)
		any |= dx | dy
	}
	moving = simd.reduce_or(any) != 0

	for ; x <= x1; x += 1 {
		r.dx[x], r.dy[x] = sandbox_intent_cell(sb, y, x)
		moving ||= r.dx[x] != 0 || r.dy[x] != 0
	}
	return moving
}

@(test)
test_the_vector_intent_agrees_with_the_plain_one :: proc(t: ^testing.T) {
	table, table_ok := load_materials("data/materials.txt")
	testing.expect(t, table_ok, "materials must load")
	defer destroy_material_table(table)

	widths := [?]i32{1, 5, 15, 16, 17, 31, 33, 64, 65, 200}
	for width in widths {
		sb, make_ok := sandbox_make(width, 24, 7)
		testing.expect(t, make_ok, "the sandbox must be created")
		defer sandbox_destroy(&sb)

		for i in 0 ..< len(sb.cells) {
			h := sandbox_chance(&sb, i32(i) % width, i32(i) / width, .React_Roll)
			sb.cells[i] = Cell(h % u32(len(table.materials)))
			sb.lifetime[i] = material_start_life(table, sb.cells[i])
			sb.moved[i] = h & 0x1F0 == 0
		}

		for y in i32(0) ..< sb.height {
			x0 := y % width
			x1 := max(x0, width - 1 - (y * 3) % width)

			_, _ = sandbox_load_row(&sb, table, y, x0, x1)
			sandbox_intent_row(&sb, y, x0, x1)

			for x in x0 ..= x1 {
				dx, dy := sandbox_intent_cell(&sb, y, x)
				testing.expectf(
					t, sb.rows.dx[x] == dx && sb.rows.dy[x] == dy,
					"width %d row %d cell %d: vector says (%d,%d), plain says (%d,%d)",
					width, y, x, sb.rows.dx[x], sb.rows.dy[x], dx, dy,
				)
			}
		}
	}
}
