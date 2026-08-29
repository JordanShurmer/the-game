package game

// What the wide weight pass needs on every machine: how many cells it
// takes at a time, how many material ids fit its shuffle tables, and the
// tables themselves. The pass is amd64 assembly and lives in
// `sandbox_step_asm.odin`; the lookup it reads is built here, because a
// table that does not fit is a fact about the materials and not about
// the machine.

import testing "check"

SANDBOX_WIDE_LANES :: 32

SANDBOX_WIDE_IDS :: 64

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
