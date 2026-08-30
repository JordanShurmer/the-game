package game

Material_State :: enum u8 {
	Solid,
	Powder,
	Liquid,
	Gas,
	Special,
	Phantom, // no physical interaction: the cell grid never holds one
	Brush,   // stands like a solid, but too slight to stop a man
}

Contact_Effect :: enum u8 {
	Burns,
}

Material :: struct {
	color:          u32,
	density:        f32,
	lifetime:       i32,
	contact:        bit_set[Contact_Effect; u32],
	state:          Material_State,
	fall_speed:     u8,
	hardness:       u8,
	flammability:   u8,
	force:          u8, // expulsive: the power and the reach of the blast it makes
	luminosity:     u8, // the light it gives
	spread:         u8, // how far a fluid looks along its row for a way on
}

#assert(size_of(Material) == 24)

// A material with no physical interaction. Matter cannot touch one and one
// cannot touch matter, so the cell grid never holds one: the world carries it
// as a light and a colour at a point. See docs/lighting.md, "Every light is a
// material".
material_is_phantom :: proc(m: Material) -> bool {
	return m.state == .Phantom
}

// Standing growth: a crop, a hedge, a stook of cut wheat. It holds its
// cell against sand and water the way a solid does and it burns and
// crumbles like anything else, but a man walks through it rather than
// into it, and what falls on it mostly sifts down through it to the
// ground at its foot -- see `sandbox_sift`, and docs/physics.md, "The
// sieve rule".
//
// It is a state and not a flag because it is a way of being matter, the
// same as being a powder is. Without it every field in the homelands is
// a wall of wheat eleven cells high and the village a maze, which is
// not what a field is.
material_is_brush :: proc(m: Material) -> bool {
	return m.state == .Brush
}
