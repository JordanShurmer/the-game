package game

import "base:intrinsics"
import "core:sys/info"
import "core:testing"

SANDBOX_WIDE_LANES :: 32

SANDBOX_WIDE_IDS :: 64

@(private = "file") B32 :: #simd[SANDBOX_WIDE_LANES]u8

// Four 16-entry shuffle tables per byte (low and high), chosen by a chain of
// three thresholds: id>15 picks block 1 over 0, id>31 picks block 2 over
// whatever block 0/1 gave, id>47 picks block 3 over that. Every id stays
// under 128, so the signed vpcmpgtb compares are still correct.
@(private = "file")
weights_32 :: asm(
	cells:      [^]u8,
	moved:      [^]u8,
	out:        [^]u16,
	lo_a:       B32,
	lo_b:       B32,
	lo_c:       B32,
	lo_d:       B32,
	hi_a:       B32,
	hi_b:       B32,
	hi_c:       B32,
	hi_d:       B32,
	fifteen:    B32,
	thirtyone:  B32,
	fortyseven: B32,
) [
	idx: B32,
	sel: B32,
	lo:  B32,
	hi:  B32,
	t:   B32,
	#clobber memory,
	#clobber flags,
] {
	vmovdqu   idx, [cells]

	vpcmpgtb  sel, idx, fifteen
	vpshufb   lo, lo_a, idx
	vpshufb   t, lo_b, idx
	vpblendvb lo, lo, t, sel
	vpcmpgtb  sel, idx, thirtyone
	vpshufb   t, lo_c, idx
	vpblendvb lo, lo, t, sel
	vpcmpgtb  sel, idx, fortyseven
	vpshufb   t, lo_d, idx
	vpblendvb lo, lo, t, sel

	vpcmpgtb  sel, idx, fifteen
	vpshufb   hi, hi_a, idx
	vpshufb   t, hi_b, idx
	vpblendvb hi, hi, t, sel
	vpcmpgtb  sel, idx, thirtyone
	vpshufb   t, hi_c, idx
	vpblendvb hi, hi, t, sel
	vpcmpgtb  sel, idx, fortyseven
	vpshufb   t, hi_d, idx
	vpblendvb hi, hi, t, sel

	vpxor     sel, sel, sel
	vmovdqu   t, [moved]
	vpcmpgtb  t, t, sel
	vpor      lo, lo, t
	vpor      hi, hi, t

	vpunpcklbw t, lo, hi
	vpunpckhbw sel, lo, hi
	vperm2i128 lo, t, sel, 0x20
	vperm2i128 hi, t, sel, 0x31

	vmovdqu   [out], lo
	vmovdqu   [out + 32], hi
}


sandbox_wide_start :: #force_inline proc "contextless" (from, last: i32) -> i32 {
	aligned := (from + SANDBOX_WIDE_LANES - 1) &~ i32(SANDBOX_WIDE_LANES - 1)
	return min(aligned, last + 1)
}

sandbox_weights_span :: proc(
	sb: ^Sandbox, table: Material_Table, out: []u16, base: int, from, last: i32,
) -> i32 {
	lut := table.weight_lut
	return weights_span(
		raw_data(sb.cells[base:]),
		([^]u8)(raw_data(sb.moved[base:])),
		raw_data(out),
		&lut, from, last,
	)
}

// 256-bit value must not cross AVX2 boundary: non-AVX2 caller passes 16-byte-aligned stack slot, AVX2 callee reads 32-byte-aligned and faults.
@(private = "file", enable_target_feature = "avx2")
weights_span :: proc "contextless" (
	cells: [^]u8,
	moved: [^]u8,
	out:   [^]u16,
	lut:   ^[8 * SANDBOX_WIDE_LANES]u8,
	from, last: i32,
) -> (x: i32) {
	W :: SANDBOX_WIDE_LANES
	lo_a := intrinsics.unaligned_load((^B32)(&lut[0]))
	lo_b := intrinsics.unaligned_load((^B32)(&lut[W]))
	lo_c := intrinsics.unaligned_load((^B32)(&lut[2 * W]))
	lo_d := intrinsics.unaligned_load((^B32)(&lut[3 * W]))
	hi_a := intrinsics.unaligned_load((^B32)(&lut[4 * W]))
	hi_b := intrinsics.unaligned_load((^B32)(&lut[5 * W]))
	hi_c := intrinsics.unaligned_load((^B32)(&lut[6 * W]))
	hi_d := intrinsics.unaligned_load((^B32)(&lut[7 * W]))

	x = from
	for ; x + W <= last + 1; x += W {
		weights_32(
			cells[x:], moved[x:], out[x + 1:],
			lo_a, lo_b, lo_c, lo_d, hi_a, hi_b, hi_c, hi_d,
			B32(15), B32(31), B32(47),
		)
	}
	return x
}

@(private = "file") wide_cpu_known:  bool
@(private = "file") wide_cpu_answer: bool

sandbox_wide_cpu :: proc "contextless" () -> bool {
	if !wide_cpu_known {
		wide_cpu_answer = .avx2 in info.cpu_features()
		wide_cpu_known = true
	}
	return wide_cpu_answer
}

sandbox_build_luts :: proc(table: ^Material_Table) {
	W :: SANDBOX_WIDE_LANES
	table.weight_lut = {}
	table.lut_ok = len(table.materials) <= SANDBOX_WIDE_IDS
	table.wide_ok = table.lut_ok && sandbox_wide_cpu()
	if !table.lut_ok do return

	for m in 0 ..< len(table.materials) {
		quarter := m / 16 * W
		lane := m % 16
		w := table.weight[m]

		table.weight_lut[quarter + lane] = u8(w)
		table.weight_lut[quarter + lane + 16] = u8(w)
		table.weight_lut[4 * W + quarter + lane] = u8(w >> 8)
		table.weight_lut[4 * W + quarter + lane + 16] = u8(w >> 8)
	}
}

@(test)
test_the_wide_weights_agree_with_the_plain_ones :: proc(t: ^testing.T) {
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
	table, table_ok := load_materials("data/materials.txt")
	testing.expect(t, table_ok, "materials must load")
	defer destroy_material_table(table)
	testing.expect(t, table.lut_ok, "the shipped table must fit the lookup")

	W :: SANDBOX_WIDE_LANES
	for m in 0 ..< len(table.materials) {
		quarter := m / 16 * W
		lane := m % 16
		w := table.weight[m]

		for second in 0 ..= 16 {
			if second != 0 && second != 16 do continue
			got := u16(table.weight_lut[quarter + lane + second]) |
			       u16(table.weight_lut[4 * W + quarter + lane + second]) << 8
			testing.expectf(
				t, got == w,
				"material %d (%s) weighs %d, and the lut quarter at +%d says %d",
				m, table.names[m], w, second, got,
			)
		}
	}
}

// A guard rail. Nothing stops a future feature from adding one row too many
// to data/materials.txt and quietly switching off the hand-written AVX2
// weight lookup for the whole sandbox — that happened once already, when a
// drudge's lamp got its own material row and pushed the table to 33. This
// test names the ceiling directly, so the next such change fails loudly
// here instead of silently in a benchmark nobody was watching.
@(test)
test_the_shipped_materials_still_fit_the_wide_lookup :: proc(t: ^testing.T) {
	table, table_ok := load_materials("data/materials.txt")
	testing.expect(t, table_ok, "materials must load")
	defer destroy_material_table(table)

	testing.expectf(
		t, len(table.materials) <= SANDBOX_WIDE_IDS,
		"the shipped table must fit the wide lookup's %d ids, and it holds %d",
		SANDBOX_WIDE_IDS, len(table.materials),
	)
	testing.expect(t, table.lut_ok, "the shipped table must set lut_ok")
}

@(test)
test_a_long_material_table_stands_the_wide_pass_down :: proc(t: ^testing.T) {
	table, table_ok := load_materials("data/materials.txt")
	testing.expect(t, table_ok, "materials must load")
	defer destroy_material_table(table)

	kept := table.materials
	defer table.materials = kept

	table.materials = make([]Material, SANDBOX_WIDE_IDS + 1)
	defer delete(table.materials)

	sandbox_build_luts(&table)
	testing.expect(t, !table.lut_ok, "a table of 65 materials must not fit the lookup")
	testing.expect(t, !table.wide_ok, "and the wide pass must stand down")
}
