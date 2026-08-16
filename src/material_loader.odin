package game

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:testing"

/*
Load materials from the simple text format in data/materials.txt.

Returns a dense slice of Material (hot data) and a parallel
slice of names (cold data). Indices match.
*/

Material_Table :: struct {
	materials: []Material,
	names:     []string,
}

load_materials :: proc(path: string, allocator := context.allocator) -> (table: Material_Table, ok: bool) {
	data, read_ok := os.read_entire_file(path, allocator)
	if !read_ok {
		return {}, false
	}
	defer delete(data, allocator)

	text := string(data)
	lines := strings.split_lines(text, allocator)
	defer delete(lines, allocator)

	materials := make([dynamic]Material, allocator)
	names     := make([dynamic]string, allocator)
	defer if !ok {
		for n in names do delete(n, allocator)
		delete(materials)
		delete(names)
	}

	current: Material
	current_name: string
	has_current := false

	flush :: proc(materials: ^[dynamic]Material, names: ^[dynamic]string, mat: Material, name: string, allocator: runtime.Allocator) {
		append(materials, mat)
		append(names, strings.clone(name, allocator))
	}

	for line in lines {
		trimmed := strings.trim_space(line)
		if len(trimmed) == 0 || trimmed[0] == '#' do continue

		// New material block
		if trimmed[0] == '[' && trimmed[len(trimmed)-1] == ']' {
			if has_current {
				flush(&materials, &names, current, current_name, allocator)
			}
			current_name = trimmed[1:len(trimmed)-1]
			current = Material{lifetime = -1} // sensible default
			has_current = true
			continue
		}

		if !has_current do continue

		// key = value
		parts := strings.split_n(trimmed, "=", 2, allocator)
		defer delete(parts, allocator)
		if len(parts) != 2 do continue

		key   := strings.trim_space(parts[0])
		value := strings.trim_space(parts[1])
		// strip inline comment
		if idx := strings.index_byte(value, '#'); idx >= 0 {
			value = strings.trim_space(value[:idx])
		}

		switch key {
		case "state":
			switch value {
			case "Solid":   current.state = .Solid
			case "Powder":  current.state = .Powder
			case "Liquid":  current.state = .Liquid
			case "Gas":     current.state = .Gas
			case "Special": current.state = .Special
			}
		case "density":
			if v, vok := strconv.parse_f32(value); vok do current.density = v
		case "fall_speed":
			if v, vok := strconv.parse_uint(value, 10); vok do current.fall_speed = u8(v)
		case "hardness":
			if v, vok := strconv.parse_uint(value, 10); vok do current.hardness = u8(v)
		case "flammability":
			if v, vok := strconv.parse_uint(value, 10); vok do current.flammability = u8(v)
		case "conductivity":
			if v, vok := strconv.parse_uint(value, 10); vok do current.conductivity = u8(v)
		case "toxicity":
			if v, vok := strconv.parse_uint(value, 10); vok do current.toxicity = u8(v)
		case "lifetime":
			if v, vok := strconv.parse_i64(value); vok do current.lifetime = i16(v)
		case "color":
			if v, vok := strconv.parse_u64_of_base(value, 16); vok do current.color = u32(v)
		case "contact":
			current.contact = parse_contact_effects(value)
		case "immersion":
			current.immersion = parse_immersion_effects(value)
		case "tags":
			current.tags = parse_reaction_tags(value)
		}
	}

	if has_current {
		flush(&materials, &names, current, current_name, allocator)
	}

	table.materials = materials[:]
	table.names     = names[:]
	return table, true
}

parse_contact_effects :: proc(s: string) -> bit_set[Contact_Effect; u16] {
	result: bit_set[Contact_Effect; u16]
	for part in strings.split(s, " ") {
		switch part {
		case "Burns":       result += {.Burns}
		case "Wets":        result += {.Wets}
		case "Freezes":     result += {.Freezes}
		case "Poisons":     result += {.Poisons}
		case "Dissolves":   result += {.Dissolves}
		case "Heals":       result += {.Heals}
		case "Electrifies": result += {.Electrifies}
		}
	}
	return result
}

parse_immersion_effects :: proc(s: string) -> bit_set[Immersion_Effect; u16] {
	result: bit_set[Immersion_Effect; u16]
	for part in strings.split(s, " ") {
		switch part {
		case "Drowns":     result += {.Drowns}
		case "Burns":      result += {.Burns}
		case "Freezes":    result += {.Freezes}
		case "Poisons":    result += {.Poisons}
		case "Heals":      result += {.Heals}
		case "Transforms": result += {.Transforms}
		}
	}
	return result
}

parse_reaction_tags :: proc(s: string) -> bit_set[Reaction_Tag; u16] {
	result: bit_set[Reaction_Tag; u16]
	for part in strings.split(s, " ") {
		switch part {
		case "Fuel":     result += {.Fuel}
		case "Oxidizer": result += {.Oxidizer}
		case "Acid":     result += {.Acid}
		case "Base":     result += {.Base}
		case "Metal":    result += {.Metal}
		case "Organic":  result += {.Organic}
		case "Magical":  result += {.Magical}
		}
	}
	return result
}

find_material_index :: proc(table: Material_Table, name: string) -> (idx: int, found: bool) {
	for n, i in table.names {
		if n == name do return i, true
	}
	return -1, false
}

// ------------------------------------------------------------
// Data-driven tests (run with: odin test src)
// ------------------------------------------------------------

@(test)
test_load_materials_count :: proc(t: ^testing.T) {
	table, ok := load_materials("data/materials.txt")
	defer {
		for n in table.names do delete(n)
		delete(table.materials)
		delete(table.names)
	}
	testing.expect(t, ok, "load must succeed")
	testing.expect(t, len(table.materials) == 12, "expected 12 materials")
	testing.expect(t, len(table.names) == 12, "names must match materials")
}

@(test)
test_water_properties :: proc(t: ^testing.T) {
	table, ok := load_materials("data/materials.txt")
	defer {
		for n in table.names do delete(n)
		delete(table.materials)
		delete(table.names)
	}
	testing.expect(t, ok)

	idx, found := find_material_index(table, "Water")
	testing.expect(t, found, "Water must exist")
	m := table.materials[idx]

	testing.expect(t, m.state == .Liquid)
	testing.expect(t, m.density == 1.0)
	testing.expect(t, m.fall_speed == 4)
	testing.expect(t, .Wets in m.contact)
	testing.expect(t, .Drowns in m.immersion)
	testing.expect(t, m.lifetime == -1)
}

@(test)
test_acid_effects_and_tags :: proc(t: ^testing.T) {
	table, ok := load_materials("data/materials.txt")
	defer {
		for n in table.names do delete(n)
		delete(table.materials)
		delete(table.names)
	}
	testing.expect(t, ok)

	idx, found := find_material_index(table, "Acid")
	testing.expect(t, found)
	m := table.materials[idx]

	testing.expect(t, .Dissolves in m.contact)
	testing.expect(t, .Poisons in m.contact)
	testing.expect(t, .Poisons in m.immersion)
	testing.expect(t, .Dissolves in m.immersion)
	testing.expect(t, .Acid in m.tags)
	testing.expect(t, m.toxicity == 6)
}

@(test)
test_fire_lifetime_and_rise :: proc(t: ^testing.T) {
	table, ok := load_materials("data/materials.txt")
	defer {
		for n in table.names do delete(n)
		delete(table.materials)
		delete(table.names)
	}
	testing.expect(t, ok)

	idx, found := find_material_index(table, "Fire")
	testing.expect(t, found)
	m := table.materials[idx]

	testing.expect(t, m.state == .Special)
	testing.expect(t, m.lifetime == 90)
	testing.expect(t, m.fall_speed == 1)
	testing.expect(t, .Burns in m.contact)
	testing.expect(t, .Oxidizer in m.tags)
}

@(test)
test_gold_density :: proc(t: ^testing.T) {
	table, ok := load_materials("data/materials.txt")
	defer {
		for n in table.names do delete(n)
		delete(table.materials)
		delete(table.names)
	}
	testing.expect(t, ok)

	idx, found := find_material_index(table, "Gold")
	testing.expect(t, found)
	m := table.materials[idx]

	testing.expect(t, m.state == .Solid)
	testing.expect(t, m.density == 19.3)
	testing.expect(t, .Metal in m.tags)
	testing.expect(t, m.fall_speed == 0)
}
