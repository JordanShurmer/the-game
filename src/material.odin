package game

/*
Material definition.

Fat struct by design. Fields that simulation and status systems
read together live here so they stay in cache.

Cold data (display name, lore text) can live in a parallel table
indexed by the same material ID later.
*/

Material_State :: enum u8 {
	Solid,
	Powder,
	Liquid,
	Gas,
	Special, // fire, plasma, temporary effects, etc.
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
	// Visual
	color:          u32, // RGBA or palette index

	// Physical behaviour (hot path)
	state:          Material_State,
	density:        f32, // higher sinks
	fall_speed:     u8,  // pixels per tick; 0 = static
	hardness:       u8,  // dig / penetrate resistance

	// Chemistry / status (hot path)
	flammability:   u8,  // 0 = none
	conductivity:   u8,  // heat / electricity
	toxicity:       u8,  // damage on contact or immersion
	lifetime:       i16, // ticks; -1 = permanent

	// Effects as bit sets
	contact:        bit_set[Contact_Effect; u16],
	immersion:      bit_set[Immersion_Effect; u16],
	tags:           bit_set[Reaction_Tag; u16],
}
