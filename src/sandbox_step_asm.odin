#+build amd64
package game

// The wide weight pass, in AVX2. It reads 32 cells at a time and comes
// out with the same weights `sandbox_weight_of` gives one at a time,
// which `test_the_wide_weights_agree_with_the_plain_ones` measures.
//
// The templates are amd64, so this whole file is amd64: a machine that
// is not amd64 builds `sandbox_step_wide_off.odin` instead and runs the
// plain path. See docs/web.md, "What the web cannot have".

import "base:intrinsics"
import "core:sys/info"


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
