package game

Material_State :: enum u8 {
	Solid,
	Powder,
	Liquid,
	Gas,
	Special,
	Phantom, // no physical interaction: the cell grid never holds one
}

Contact_Effect :: enum u8 {
	Burns,
	Wets,
	Freezes,
	Poisons,
	Dissolves,
	Heals,
	Electrifies,
}

Immersion_Effect :: enum u8 {
	Drowns,
	Burns,
	Freezes,
	Poisons,
	Dissolves,
	Heals,
	Transforms,
}

Reaction_Tag :: enum u8 {
	Fuel,
	Oxidizer,
	Acid,
	Base,
	Metal,
	Organic,
	Magical,
}

Material :: struct {
	color:          u32,
	density:        f32,
	lifetime:       i32,
	contact:        bit_set[Contact_Effect; u32],
	immersion:      bit_set[Immersion_Effect; u32],
	tags:           bit_set[Reaction_Tag; u32],
	state:          Material_State,
	fall_speed:     u8,
	hardness:       u8,
	flammability:   u8,
	conductivity:   u8,
	toxicity:       u8,
	force:          u8, // expulsive: the power and the reach of the blast it makes
	luminosity:     u8, // the light it gives
}

#assert(size_of(Material) == 32)

// A material with no physical interaction. Matter cannot touch one and one
// cannot touch matter, so the cell grid never holds one: the world carries it
// as a light and a colour at a point. See docs/lighting.md, "Every light is a
// material".
material_is_phantom :: proc(m: Material) -> bool {
	return m.state == .Phantom
}
