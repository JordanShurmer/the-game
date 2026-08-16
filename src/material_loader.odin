package game

import "core:os"
import "core:strconv"
import "core:strings"
import "core:testing"

/*
Load materials from data/materials.txt using the shared tokenizer.
*/

load_materials :: proc(path: string, allocator := context.allocator) -> (table: Material_Table, err: Config_Error, ok: bool) {
	data, read_ok := os.read_entire_file(path, allocator)
	if !read_ok {
		return {}, Config_Error{path, 0, "", "could not read file"}, false
	}
	defer delete(data, allocator)

	sections, tok_err, tok_ok := tokenize_config(string(data), path, allocator)
	if !tok_ok {
		return {}, tok_err, false
	}
	defer free_config_sections(sections, allocator)

	materials := make([dynamic]Material, allocator)
	names     := make([dynamic]string, allocator)
	defer if !ok {
		for n in names do delete(n, allocator)
		delete(materials)
		delete(names)
	}

	for sec in sections {
		mat := Material{lifetime = -1}
		name := strings.clone(sec.name, allocator)

		for kv in sec.kvs {
			switch kv.key {
			case "state":
				switch kv.value {
				case "Solid":   mat.state = .Solid
				case "Powder":  mat.state = .Powder
				case "Liquid":  mat.state = .Liquid
				case "Gas":     mat.state = .Gas
				case "Special": mat.state = .Special
				case:
					return {}, Config_Error{path, kv.line, kv.value, "unknown state"}, false
				}
			case "density":
				v, vok := strconv.parse_f32(kv.value)
				if !vok {
					return {}, Config_Error{path, kv.line, kv.value, "bad density"}, false
				}
				mat.density = v
			case "fall_speed":
				v, vok := strconv.parse_uint(kv.value, 10)
				if !vok {
					return {}, Config_Error{path, kv.line, kv.value, "bad fall_speed"}, false
				}
				mat.fall_speed = u8(v)
			case "hardness":
				v, vok := strconv.parse_uint(kv.value, 10)
				if !vok {
					return {}, Config_Error{path, kv.line, kv.value, "bad hardness"}, false
				}
				mat.hardness = u8(v)
			case "flammability":
				v, vok := strconv.parse_uint(kv.value, 10)
				if !vok {
					return {}, Config_Error{path, kv.line, kv.value, "bad flammability"}, false
				}
				mat.flammability = u8(v)
			case "conductivity":
				v, vok := strconv.parse_uint(kv.value, 10)
				if !vok {
					return {}, Config_Error{path, kv.line, kv.value, "bad conductivity"}, false
				}
				mat.conductivity = u8(v)
			case "toxicity":
				v, vok := strconv.parse_uint(kv.value, 10)
				if !vok {
					return {}, Config_Error{path, kv.line, kv.value, "bad toxicity"}, false
				}
				mat.toxicity = u8(v)
			case "lifetime":
				v, vok := strconv.parse_i64(kv.value)
				if !vok {
					return {}, Config_Error{path, kv.line, kv.value, "bad lifetime"}, false
				}
				mat.lifetime = i32(v)
			case "color":
				v, vok := parse_hex_u32(kv.value)
				if !vok {
					return {}, Config_Error{path, kv.line, kv.value, "bad color"}, false
				}
				mat.color = v
			case "contact":
				bs, bok := parse_contact_effects(kv.value, path, kv.line)
				if !bok {
					return {}, Config_Error{path, kv.line, kv.value, "unknown contact effect"}, false
				}
				mat.contact = bs
			case "immersion":
				bs, bok := parse_immersion_effects(kv.value, path, kv.line)
				if !bok {
					return {}, Config_Error{path, kv.line, kv.value, "unknown immersion effect"}, false
				}
				mat.immersion = bs
			case "tags":
				bs, bok := parse_reaction_tags(kv.value, path, kv.line)
				if !bok {
					return {}, Config_Error{path, kv.line, kv.value, "unknown reaction tag"}, false
				}
				mat.tags = bs
			case:
				return {}, Config_Error{path, kv.line, kv.key, "unknown key"}, false
			}
		}

		append(&materials, mat)
		append(&names, name)
	}

	table.materials = materials[:]
	table.names = names[:]
	return table, {}, true
}

parse_contact_effects :: proc(s: string, file: string, line: int) -> (bit_set[Contact_Effect; u32], bool) {
	result: bit_set[Contact_Effect; u32]
	s := s
	for part in strings.fields_iterator(&s) {
		switch part {
		case "Burns":       result += {.Burns}
		case "Wets":        result += {.Wets}
		case "Freezes":     result += {.Freezes}
		case "Poisons":     result += {.Poisons}
		case "Dissolves":   result += {.Dissolves}
		case "Heals":       result += {.Heals}
		case "Electrifies": result += {.Electrifies}
		case:
			return {}, false
		}
	}
	return result, true
}

parse_immersion_effects :: proc(s: string, file: string, line: int) -> (bit_set[Immersion_Effect; u32], bool) {
	result: bit_set[Immersion_Effect; u32]
	s := s
	for part in strings.fields_iterator(&s) {
		switch part {
		case "Drowns":     result += {.Drowns}
		case "Burns":      result += {.Burns}
		case "Freezes":    result += {.Freezes}
		case "Poisons":    result += {.Poisons}
		case "Dissolves":  result += {.Dissolves}
		case "Heals":      result += {.Heals}
		case "Transforms": result += {.Transforms}
		case:
			return {}, false
		}
	}
	return result, true
}

parse_reaction_tags :: proc(s: string, file: string, line: int) -> (bit_set[Reaction_Tag; u32], bool) {
	result: bit_set[Reaction_Tag; u32]
	s := s
	for part in strings.fields_iterator(&s) {
		switch part {
		case "Fuel":     result += {.Fuel}
		case "Oxidizer": result += {.Oxidizer}
		case "Acid":     result += {.Acid}
		case "Base":     result += {.Base}
		case "Metal":    result += {.Metal}
		case "Organic":  result += {.Organic}
		case "Magical":  result += {.Magical}
		case:
			return {}, false
		}
	}
	return result, true
}

// ------------------------------------------------------------
// Tests (run with: odin test src  from repo root)
// ------------------------------------------------------------

@(test)
test_load_materials_count :: proc(t: ^testing.T) {
	table, err, ok := load_materials("data/materials.txt")
	defer destroy_material_table(table)
	testing.expect(t, ok, format_config_error(err))
	testing.expect(t, len(table.materials) == 12, "expected 12 materials")
	testing.expect(t, len(table.names) == 12, "names must match materials")
}

@(test)
test_dirt_color_parses :: proc(t: ^testing.T) {
	// Pins the 0x prefix handling. Without it every color is 0.
	table, err, ok := load_materials("data/materials.txt")
	defer destroy_material_table(table)
	testing.expect(t, ok, format_config_error(err))

	id, found := find_material_id(table, "Dirt")
	testing.expect(t, found, "Dirt must exist")
	testing.expect(t, table.materials[id].color == 0xFF5C4033, "Dirt color must be 0xFF5C4033")
}

@(test)
test_water_properties :: proc(t: ^testing.T) {
	table, err, ok := load_materials("data/materials.txt")
	defer destroy_material_table(table)
	testing.expect(t, ok, format_config_error(err))

	id, found := find_material_id(table, "Water")
	testing.expect(t, found, "Water must exist")
	m := table.materials[id]

	testing.expect(t, m.state == .Liquid)
	testing.expect(t, m.density == 1.0)
	testing.expect(t, m.fall_speed == 4)
	testing.expect(t, .Wets in m.contact)
	testing.expect(t, .Drowns in m.immersion)
	testing.expect(t, m.lifetime == -1)
}

@(test)
test_acid_effects_and_tags :: proc(t: ^testing.T) {
	table, err, ok := load_materials("data/materials.txt")
	defer destroy_material_table(table)
	testing.expect(t, ok, format_config_error(err))

	id, found := find_material_id(table, "Acid")
	testing.expect(t, found)
	m := table.materials[id]

	testing.expect(t, .Dissolves in m.contact)
	testing.expect(t, .Poisons in m.contact)
	testing.expect(t, .Poisons in m.immersion)
	testing.expect(t, .Dissolves in m.immersion)
	testing.expect(t, .Acid in m.tags)
	testing.expect(t, m.toxicity == 6)
}

@(test)
test_fire_lifetime_and_rise :: proc(t: ^testing.T) {
	table, err, ok := load_materials("data/materials.txt")
	defer destroy_material_table(table)
	testing.expect(t, ok, format_config_error(err))

	id, found := find_material_id(table, "Fire")
	testing.expect(t, found)
	m := table.materials[id]

	testing.expect(t, m.state == .Special)
	testing.expect(t, m.lifetime == 90)
	testing.expect(t, m.fall_speed == 1)
	testing.expect(t, .Burns in m.contact)
	testing.expect(t, .Oxidizer in m.tags)
}

@(test)
test_gold_density :: proc(t: ^testing.T) {
	table, err, ok := load_materials("data/materials.txt")
	defer destroy_material_table(table)
	testing.expect(t, ok, format_config_error(err))

	id, found := find_material_id(table, "Gold")
	testing.expect(t, found)
	m := table.materials[id]

	testing.expect(t, m.state == .Solid)
	testing.expect(t, m.density == 19.3)
	testing.expect(t, .Metal in m.tags)
	testing.expect(t, m.fall_speed == 0)
}

@(test)
test_parse_hex_u32 :: proc(t: ^testing.T) {
	v, ok := parse_hex_u32("0xFF5C4033")
	testing.expect(t, ok)
	testing.expect(t, v == 0xFF5C4033)

	v, ok = parse_hex_u32("FF5C4033")
	testing.expect(t, ok)
	testing.expect(t, v == 0xFF5C4033)

	_, ok = parse_hex_u32("")
	testing.expect(t, !ok)

	_, ok = parse_hex_u32("0x")
	testing.expect(t, !ok)
}
