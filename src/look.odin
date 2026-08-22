package game

// A bench to look at one material by.
//
// A shader is judged by the picture, and a vein of gold four cells wide
// in an unlit cave says almost nothing about the shader that drew it.
// This fills the whole view with one material instead, in the shapes a
// shader has to answer for: a solid body with no edge in it, discs from
// one cell across to fifty, a thin vein, a scatter of grains, and a
// broken face of noise. Then it lights the lot from a fixed point, so
// two pictures taken a day apart may be laid over each other.
//
//     ./bin/the-game look=Gold shot=shots/gold.png
//
// The light stands where a wizard would hold it, over the left shoulder
// and a little above, and a second, dimmer one stands low on the right,
// so a surface has two directions to answer and a flat one shows up.

// The bench must show the material at every light it will ever meet, so
// the two lamps fall off hard: the top left burns and the bottom right
// keeps almost nothing.
LOOK_KEY_LUX :: 262.0
LOOK_KEY_REACH :: 118.0
LOOK_FILL_LUX :: 96.0
LOOK_FILL_REACH :: 74.0
LOOK_AMBIENT :: 5.0

// Where the two lights stand, as a part of the view.
LOOK_KEY_X :: 0.30
LOOK_KEY_Y :: 0.16
LOOK_FILL_X :: 0.86
LOOK_FILL_Y :: 0.74

Look :: struct {
	cell: Cell,
	name: string,
	on:   bool,
}

// The bench is a picture, so it is written in the coordinates of the
// picture: 0 to 1 across and 0 to 1 down, whatever the view measures.
look_solid :: proc(u, v: f32) -> bool {
	// A body with no edge in it: the top left quarter is filled.
	if u < 0.30 && v < 0.42 do return true

	// Discs, from one cell across to fifty, along the top.
	if v < 0.42 {
		centres := [5][2]f32{{0.40, 0.20}, {0.51, 0.20}, {0.64, 0.20}, {0.80, 0.20}, {0.94, 0.21}}
		radii := [5]f32{0.008, 0.020, 0.038, 0.060, 0.085}
		for c, i in centres {
			du := u - c[0]
			dv := (v - c[1]) * 0.5625 // the view is wider than it is tall
			if du * du + dv * dv < radii[i] * radii[i] do return true
		}
	}

	// A vein: thin, and it wanders, which is how ore lies in rock.
	{
		wander := 0.52 + 0.055 * look_wave(u * 9.0) + 0.02 * look_wave(u * 23.0 + 4.0)
		if abs(v - wander) < 0.010 do return true
	}

	// A broken face of noise: the shape a real body of the material takes.
	if v > 0.62 {
		fall := (v - 0.62) / 0.38
		n := look_noise(u * 7.0, v * 4.0) * 0.62 + look_noise(u * 19.0, v * 11.0) * 0.38
		if n < 0.30 + fall * 0.62 do return true
	}

	// A scatter of grains, to see what a lone cell of the material does.
	if v > 0.46 && v < 0.58 {
		if look_grain(u, v) do return true
	}

	return false
}

@(private = "file")
look_wave :: proc(x: f32) -> f32 {
	// A cheap wave: the triangle of the fractional part, smoothed.
	f := x - f32(int(x))
	if f < 0 do f += 1
	t := abs(f * 2 - 1) * 2 - 1
	return t * t * (3 - 2 * abs(t)) * (1 if t >= 0 else -1)
}

@(private = "file")
look_hash :: proc(x, y: i32) -> f32 {
	h := u32(x) * 374761393 + u32(y) * 668265263
	h = (h ~ (h >> 13)) * 1274126177
	return f32(h ~ (h >> 16)) / f32(max(u32))
}

@(private = "file")
look_noise :: proc(x, y: f32) -> f32 {
	ix := i32(x)
	iy := i32(y)
	if x < 0 do ix -= 1
	if y < 0 do iy -= 1
	fx := x - f32(ix)
	fy := y - f32(iy)
	sx := fx * fx * (3 - 2 * fx)
	sy := fy * fy * (3 - 2 * fy)

	a := look_hash(ix, iy)
	b := look_hash(ix + 1, iy)
	c := look_hash(ix, iy + 1)
	d := look_hash(ix + 1, iy + 1)
	return (a + (b - a) * sx) + ((c + (d - c) * sx) - (a + (b - a) * sx)) * sy
}

@(private = "file")
look_grain :: proc(u, v: f32) -> bool {
	gx := i32(u * 46)
	gy := i32(v * 26)
	if look_hash(gx, gy) < 0.72 do return false
	// One cell in the middle of the box, so the grains never touch.
	return abs(u * 46 - f32(gx) - 0.5) < 0.16 && abs(v * 26 - f32(gy) - 0.5) < 0.30
}

// The light on a point of the bench, which two lamps give.
look_lux :: proc(u, v: f32) -> u8 {
	lamp :: proc(u, v, lx, ly, peak, reach: f32) -> f32 {
		du := (u - lx) * 100
		dv := (v - ly) * 56.25
		d := du * du + dv * dv
		fall := reach * reach / (reach * reach + d * 26)
		return peak * fall
	}

	total: f32 = LOOK_AMBIENT
	total += lamp(u, v, LOOK_KEY_X, LOOK_KEY_Y, LOOK_KEY_LUX, LOOK_KEY_REACH)
	total += lamp(u, v, LOOK_FILL_X, LOOK_FILL_Y, LOOK_FILL_LUX, LOOK_FILL_REACH)
	if total > 255 do total = 255
	return u8(total)
}

// Draw the bench into the cells and the light the view shades by.
look_fill :: proc(look: Look, cells: []Cell, lux: []u8, w, h: i32, air: Cell) {
	for y in 0 ..< int(h) {
		v := (f32(y) + 0.5) / f32(h)
		row := cells[y * int(w):][:w]
		lit := lux[y * int(w):][:w]

		for x in 0 ..< int(w) {
			u := (f32(x) + 0.5) / f32(w)
			row[x] = look.cell if look_solid(u, v) else air
			lit[x] = look_lux(u, v)
		}
	}
}
