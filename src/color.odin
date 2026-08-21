package game

import rl "vendor:raylib"

argb_from_rl :: proc(c: rl.Color) -> u32 {
	return u32(c.a) << 24 | u32(c.r) << 16 | u32(c.g) << 8 | u32(c.b)
}

rl_from_argb :: proc(argb: u32) -> rl.Color {
	return rl.Color{u8(argb >> 16), u8(argb >> 8), u8(argb), u8(argb >> 24)}
}

blend_over :: proc(fg, bg: rl.Color) -> rl.Color {
	if fg.a == 255 do return fg

	over :: proc(fg, bg: u8, a: f32) -> u8 {
		return u8(f32(fg) * a + f32(bg) * (1 - a))
	}

	a := f32(fg.a) / 255
	return rl.Color{over(fg.r, bg.r, a), over(fg.g, bg.g, a), over(fg.b, bg.b, a), 255}
}
