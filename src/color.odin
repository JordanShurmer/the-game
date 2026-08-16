package game

import rl "vendor:raylib"

/*
Colors in the data files are 0xAARRGGBB. Raylib wants R,G,B,A bytes.
Both the map images and the world view cross this line, so the
conversion lives in one place.
*/

argb_from_rl :: proc(c: rl.Color) -> u32 {
	return u32(c.a) << 24 | u32(c.r) << 16 | u32(c.g) << 8 | u32(c.b)
}

rl_from_argb :: proc(argb: u32) -> rl.Color {
	return rl.Color{u8(argb >> 16), u8(argb >> 8), u8(argb), u8(argb >> 24)}
}
