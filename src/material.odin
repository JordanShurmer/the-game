package game

/*
Material definition.

Fat struct by design. Fields that simulation and status systems
read together live here so they stay in cache.

Cold data (display name, lore text) lives in Material_Table.
*/

Material_ID :: distinct u16

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

// Fields are ordered largest-first so the struct has no interior
// padding. Bit sets are u32 to leave room for up to 32 flags each.
Material :: struct {
	// Visual
	color:          u32, // 0xAARRGGBB

	// Physical behaviour (hot path)
	density:        f32, // higher sinks
	lifetime:       i32, // ticks; -1 = permanent

	// Effects as bit sets
	contact:        bit_set[Contact_Effect; u32],
	immersion:      bit_set[Immersion_Effect; u32],
	tags:           bit_set[Reaction_Tag; u32],

	// Small scalars last
	state:          Material_State,
	fall_speed:     u8,  // pixels per tick; 0 = static
	hardness:       u8,  // dig / penetrate resistance
	flammability:   u8,  // 0 = none
	conductivity:   u8,  // heat / electricity
	toxicity:       u8,  // damage on contact or immersion
}

// Two materials per 64-byte cache line; keep it that way.
#assert(size_of(Material) == 32)

Material_Table :: struct {
	materials: []Material,
	names:     []string, // owned; free with destroy_material_table
}

destroy_material_table :: proc(table: Material_Table, allocator := context.allocator) {
	for n in table.names {
		delete(n, allocator)
	}
	delete(table.names, allocator)
	delete(table.materials, allocator)
}

find_material_id :: proc(table: Material_Table, name: string) -> (id: Material_ID, found: bool) {
	for n, i in table.names {
		if n == name {
			return Material_ID(i), true
		}
	}
	return 0, false
}
