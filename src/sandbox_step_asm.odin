package game

import "base:intrinsics"
import "core:sys/info"
import "core:testing"

/*
LOAD, a vector of cells at a time, in amd64 assembly.

The step reads three rows of weights for every row it steps: the row
above, the row itself, and the row below. That is where the tick goes
(docs/physics.md, "Where the tick goes now"), and two of the three
come through sandbox_load_weights, which is what this file makes wide.

The rule is one line, and sandbox_weight_of in sandbox_step.odin is
it: a cell's weight is the weight of its material, and a cell that
already moved this tick is a wall. weights_32 below is that same line
for SANDBOX_WIDE_LANES cells at once, and
test_the_wide_weights_agree_with_the_plain_ones holds the two to the
same answer over every material, over ragged spans, and over rows that
do not fill a vector.

WHY A LOOKUP WORKS AT ALL

A material id is a u8 (`Cell` in src/worldgen.odin), so 32 cells are
32 bytes and one load. `vpshufb` turns 16 such ids into 16 table
entries in one instruction, and two of them with a blend cover the
SANDBOX_WIDE_IDS ids a pair of tables can hold. The world ships with
27 materials, so the whole material table is a lookup.

A weight is a u16 and vpshufb only reads bytes, so the table is split
into the low byte of every weight and the high byte of every weight.
Each is looked up on its own and the two are interleaved back into
words at the end.

WHY THIS ONE IS ASSEMBLY

Odin reaches vpshufb through `simd.runtime_swizzle`, so the lookup on
its own needs no assembly. What earns it is the tail of the sequence.
`vpunpcklbw` and `vperm2i128` both work inside the two 128 bit halves
of a 256 bit register, so the interleave leaves the words in the order
0..7, 16..23, 8..15, 24..31, and putting them back is part of the
operation rather than a mistake to avoid. Written as an asm template
that is two named instructions next to the two that caused it. Written
portably it is a shuffle whose constants have to be read twice to
believe, and whose lowering is a hope rather than a promise.

WHAT IT COSTS, AND WHAT IT DOES NOT

Two conditions, and both fall back rather than fail. The plain loop is
still there, still correct, and still what runs when either fails:

  - **AVX2.** The template is 256 bit. A machine without AVX2 takes
    the plain path. The CPU is asked once, when the materials load.
  - **SANDBOX_WIDE_IDS materials.** Two vpshufb tables hold 32 ids. A
    world with more materials than that takes the plain path too, so
    the material table stays as open as it was.

Measured with bin/bench on a 2048 square sandbox, against the same
build without it: Sandcave -10%, Oilfield -10%, Acidpool -10%, Lake
-8%, Gallery -7%, Coalmine -5%. Every checksum is unchanged, which is
the point: this is the same rule, and only the cost is different.
*/

// Cells one instantiation of the template answers. 32 material ids are
// 32 bytes, which is one AVX2 register.
SANDBOX_WIDE_LANES :: 32

// Material ids two vpshufb tables can hold. A longer material table
// takes the plain path.
SANDBOX_WIDE_IDS :: 32

@(private = "file") B32 :: #simd[SANDBOX_WIDE_LANES]u8

/*
The weights of SANDBOX_WIDE_LANES cells, written to `out` as u16.

`lo_a` holds the low byte of the weight of ids 0 to 15 and `lo_b` the
same for ids 16 to 31; `hi_a` and `hi_b` are the high bytes of those
two halves. Each table is 16 entries written twice, because vpshufb
reads a 256 bit register as two 128 bit lanes and each lane indexes
its own half.

`cells` and `moved` are read for SANDBOX_WIDE_LANES cells and `out` is
written for as many u16. sandbox_weights_span only calls this where
all of that is inside the row.
*/
@(private = "file")
weights_32 :: asm(
	cells:   [^]u8,
	moved:   [^]u8,
	out:     [^]u16,
	lo_a:    B32,
	lo_b:    B32,
	hi_a:    B32,
	hi_b:    B32,
	fifteen: B32,
) [
	idx: B32,
	sel: B32,
	lo:  B32,
	hi:  B32,
	t:   B32,
	u:   B32,
	#clobber memory,
	#clobber flags,
] {
	// One id per byte, and one comparison that says which of the two
	// tables each of them belongs to: vpshufb reads only the low four
	// bits of an index, so ids above 15 come out of the first table as
	// the wrong entry and have to be taken from the second.
	vmovdqu   idx, [cells]
	vpcmpgtb  sel, idx, fifteen

	vpshufb   lo, lo_a, idx
	vpshufb   t, lo_b, idx
	vpblendvb lo, lo, t, sel

	vpshufb   hi, hi_a, idx
	vpshufb   t, hi_b, idx
	vpblendvb hi, hi, t, sel

	// A cell that already moved this tick is CELL_WALL, which is every
	// bit set, so it is one OR into each half. `moved` is a bool, so
	// it is 1 where it is set and a signed compare against zero
	// spreads that to the whole byte.
	vpxor     u, u, u
	vmovdqu   t, [moved]
	vpcmpgtb  t, t, u
	vpor      lo, lo, t
	vpor      hi, hi, t

	// Bytes back into words. Each unpack works inside its own 128 bit
	// half, so t holds the cells 0..7 and 16..23 and u holds 8..15 and
	// 24..31. The two vperm2i128 put those four quarters in order.
	vpunpcklbw t, lo, hi
	vpunpckhbw u, lo, hi
	vperm2i128 lo, t, u, 0x20
	vperm2i128 hi, t, u, 0x31

	vmovdqu   [out], lo
	vmovdqu   [out + 32], hi
}

/*
The first cell at or after `from` that a wide group can start on, and
never past the end of the span.

The wide loop takes whole groups from a multiple of
SANDBOX_WIDE_LANES, so the plain loop runs up to here first. Working
that out once beats testing the alignment of every cell, which on a
short dry row is the whole row.
*/
sandbox_wide_start :: #force_inline proc "contextless" (from, last: i32) -> i32 {
	aligned := (from + SANDBOX_WIDE_LANES - 1) &~ i32(SANDBOX_WIDE_LANES - 1)
	return min(aligned, last + 1)
}

/*
Write the weights of a row in whole groups, from cell `from` on.

The result is the first cell it did not write, which is where the
plain loop in sandbox_load_weights takes over.
*/
sandbox_weights_span :: proc(
	sb: ^Sandbox, table: Material_Table, out: []u16, base: int, from, last: i32,
) -> i32 {
	// A local, because `table` is a value and its array field has no
	// address of its own to take.
	lut := table.weight_lut
	return weights_span(
		raw_data(sb.cells[base:]),
		([^]u8)(raw_data(sb.moved[base:])),
		raw_data(out),
		&lut, from, last,
	)
}

/*
The wide run of one row, and the only caller of the template.

The attribute is what lets a 256 bit value live in a register without
raising the baseline of the whole binary. It also draws a line that no
256 bit value may cross: a caller without AVX2 hands one over on the
stack aligned to 16, and a callee with AVX2 reads it back with a 32
byte aligned load, which faults. So the loop lives on this side of the
line and the tables are built on this side; what crosses is a pointer.
*/
@(private = "file", enable_target_feature = "avx2")
weights_span :: proc "contextless" (
	cells: [^]u8,
	moved: [^]u8,
	out:   [^]u16,
	lut:   ^[4 * SANDBOX_WIDE_LANES]u8,
	from, last: i32,
) -> (x: i32) {
	W :: SANDBOX_WIDE_LANES
	lo_a := intrinsics.unaligned_load((^B32)(&lut[0]))
	lo_b := intrinsics.unaligned_load((^B32)(&lut[W]))
	hi_a := intrinsics.unaligned_load((^B32)(&lut[2 * W]))
	hi_b := intrinsics.unaligned_load((^B32)(&lut[3 * W]))

	x = from
	for ; x + W <= last + 1; x += W {
		// The weight rows carry one entry at each end, so cell x is
		// entry x + 1. See Sandbox_Rows.
		weights_32(cells[x:], moved[x:], out[x + 1:], lo_a, lo_b, hi_a, hi_b, B32(15))
	}
	return x
}

/*
Whether this machine can run the templates.

Asked once, when the materials load. info.cpu_features reads CPUID,
which is not something to do on every row.
*/
@(private = "file") wide_cpu_known:  bool
@(private = "file") wide_cpu_answer: bool

sandbox_wide_cpu :: proc "contextless" () -> bool {
	if !wide_cpu_known {
		wide_cpu_answer = .avx2 in info.cpu_features()
		wide_cpu_known = true
	}
	return wide_cpu_answer
}

/*
The vpshufb tables, built once when the materials load.

Every table is 16 entries written twice, because vpshufb indexes
within each 128 bit lane of a 256 bit register and both lanes must
reach the same 16 entries. Two of them cover the SANDBOX_WIDE_IDS ids
a lookup holds: the first is ids 0 to 15 and the second ids 16 to 31.

	weight_lut  the low byte of every weight, then the high byte

A table with more materials than SANDBOX_WIDE_IDS cannot be held this
way. `wide_ok` then stays false, the wide pass stands down, and the
plain loop does the whole row.
*/
sandbox_build_luts :: proc(table: ^Material_Table) {
	W :: SANDBOX_WIDE_LANES
	table.weight_lut = {}
	table.lut_ok = len(table.materials) <= SANDBOX_WIDE_IDS
	table.wide_ok = table.lut_ok && sandbox_wide_cpu()
	if !table.lut_ok do return

	for m in 0 ..< len(table.materials) {
		half := m / 16 * W // 0 for ids 0 to 15, 32 for ids 16 to 31
		lane := m % 16
		w := table.weight[m]

		table.weight_lut[half + lane] = u8(w)
		table.weight_lut[half + lane + 16] = u8(w)
		table.weight_lut[2 * W + half + lane] = u8(w >> 8)
		table.weight_lut[2 * W + half + lane + 16] = u8(w >> 8)
	}
}

// ------------------------------------------------------------
// Tests (run with: odin test src  from repo root)
// ------------------------------------------------------------

@(test)
test_the_wide_weights_agree_with_the_plain_ones :: proc(t: ^testing.T) {
	// The template and sandbox_weight_of are one rule written twice,
	// and this is what holds them together.
	//
	// The widths and the spans are ragged on purpose. A span is a
	// dirty rectangle, so it starts and ends wherever the last tick
	// left it: everything under SANDBOX_WIDE_LANES, everything either
	// side of it, and a span that ends on the last cell of the row all
	// have to come out the same both ways.
	table, table_ok := load_materials("data/materials.txt")
	testing.expect(t, table_ok, "materials must load")
	defer destroy_material_table(table)

	testing.expect(
		t, table.lut_ok,
		"the shipped table must fit the lookup, or this test only runs the plain path",
	)

	widths := [?]i32{1, 5, 31, 32, 33, 63, 64, 65, 127, 200}
	for width in widths {
		sb, make_ok := sandbox_make(width, 24, 11)
		testing.expect(t, make_ok, "the sandbox must be created")
		defer sandbox_destroy(&sb)

		// Every material, and a scatter of cells already moved, so the
		// wall rule is tested along with the lookup.
		for i in 0 ..< len(sb.cells) {
			h := sandbox_chance(&sb, i32(i) % width, i32(i) / width, .React_Roll)
			sb.cells[i] = Cell(h % u32(len(table.materials)))
			sb.moved[i] = h & 0x1F0 == 0
		}

		want := make([]u16, width + 2)
		defer delete(want)

		for y in i32(0) ..< sb.height {
			lo := y % width
			hi := max(lo, width - 1 - (y * 3) % width)

			base := sandbox_index(&sb, 0, y)
			for x in lo ..= hi do want[x + 1] = sandbox_weight_of(&sb, table, base + int(x))

			sandbox_load_weights(&sb, table, sb.rows.above, y, lo, hi)

			for x in lo ..= hi {
				testing.expectf(
					t, sb.rows.above[x + 1] == want[x + 1],
					"width %d row %d cell %d: wide says %d, plain says %d",
					width, y, x, sb.rows.above[x + 1], want[x + 1],
				)
			}
		}
	}
}

@(test)
test_the_weight_lut_holds_every_material :: proc(t: ^testing.T) {
	// The lut is the material table as the template reads it, so an
	// entry that is wrong is a material with the wrong weight, which
	// is a material that falls through the wrong things.
	table, table_ok := load_materials("data/materials.txt")
	testing.expect(t, table_ok, "materials must load")
	defer destroy_material_table(table)
	testing.expect(t, table.lut_ok, "the shipped table must fit the lookup")

	W :: SANDBOX_WIDE_LANES
	for m in 0 ..< len(table.materials) {
		half := m / 16 * W
		lane := m % 16
		w := table.weight[m]

		// Both 128 bit lanes of both tables must carry the same entry.
		for second in 0 ..= 16 {
			if second != 0 && second != 16 do continue
			got := u16(table.weight_lut[half + lane + second]) |
			       u16(table.weight_lut[2 * W + half + lane + second]) << 8
			testing.expectf(
				t, got == w,
				"material %d (%s) weighs %d, and the lut half at +%d says %d",
				m, table.names[m], w, second, got,
			)
		}
	}
}

@(test)
test_a_long_material_table_stands_the_wide_pass_down :: proc(t: ^testing.T) {
	// The wide pass caps at SANDBOX_WIDE_IDS materials, and the game
	// must not. This is the fallback that keeps the material table
	// open: too many materials, and the plain loop does the work.
	table, table_ok := load_materials("data/materials.txt")
	testing.expect(t, table_ok, "materials must load")
	defer destroy_material_table(table)

	kept := table.materials
	defer table.materials = kept

	// Pretend the table is longer than a lookup can hold. Nothing else
	// about it changes, so what this measures is the gate alone.
	table.materials = make([]Material, SANDBOX_WIDE_IDS + 1)
	defer delete(table.materials)

	sandbox_build_luts(&table)
	testing.expect(t, !table.lut_ok, "a table of 33 materials must not fit the lookup")
	testing.expect(t, !table.wide_ok, "and the wide pass must stand down")
}
