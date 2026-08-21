package game

Material_State :: enum u8 {
	Solid,
	Powder,
	Liquid,
	Gas,
	Special,
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
	explosive:      u8,
}

#assert(size_of(Material) == 32)
