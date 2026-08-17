package game

import "base:runtime"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:testing"

/*
Load materials from the simple text format in data/materials.txt.

The result holds one hot table and several cold tables. All tables
use the same index. The simulation reads `materials` every tick.
The other tables serve display and reactions, so they stay out of
the hot struct.
*/

Material_Table :: struct {
	materials: []Material, // hot: read every tick
	names:     []string,   // cold: display
	glyphs:    []u8,       // cold: one character for the text map
	decays_to: []u16,      // cold: material after the lifetime ends
	burns_to:  []u16,      // cold: material after fire reaches it
}

load_materials :: proc(path: string, allocator := context.allocator) -> (table: Material_Table, ok: bool) {
	data, read_err := os.read_entire_file(path, allocator)
	if read_err != nil {
		return {}, false
	}
	defer delete(data, allocator)

	text := string(data)

	materials := make([dynamic]Material, allocator)
	names     := make([dynamic]string, allocator)
	glyphs    := make([dynamic]u8, allocator)
	decays_to := make([dynamic]u16, allocator)
	burns_to  := make([dynamic]u16, allocator)

	// Names of the reaction targets. They point into `text`, so they
	// stay valid until this procedure returns.
	decay_names := make([dynamic]string, context.temp_allocator)
	burn_names  := make([dynamic]string, context.temp_allocator)

	defer if !ok {
		for n in names do delete(n, allocator)
		delete(materials)
		delete(names)
		delete(glyphs)
		delete(decays_to)
		delete(burns_to)
	}

	current:       Material
	current_name:  string
	current_glyph: u8
	current_decay: string
	current_burn:  string
	has_current := false

	for line in strings.split_lines_iterator(&text) {
		trimmed := strings.trim_space(line)
		if len(trimmed) == 0 || trimmed[0] == '#' do continue

		// New material block
		if trimmed[0] == '[' && trimmed[len(trimmed)-1] == ']' {
			if has_current {
				append_material(&materials, &names, &glyphs, &decay_names, &burn_names,
				                current, current_name, current_glyph, current_decay, current_burn, allocator)
			}
			current_name  = trimmed[1:len(trimmed)-1]
			current       = Material{lifetime = -1} // sensible default
			current_glyph = 0
			current_decay = ""
			current_burn  = ""
			has_current   = true
			continue
		}

		if !has_current do continue

		// key = value
		eq := strings.index_byte(trimmed, '=')
		if eq < 0 do continue

		key := strings.trim_space(trimmed[:eq])
		raw := strings.trim_space(trimmed[eq+1:])
		// A glyph can be '#', so the comment strip must not touch it.
		value := raw
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
			if v, vok := strconv.parse_i64(value); vok do current.lifetime = i32(v)
		case "color":
			// Values carry a 0x prefix, so the parser must accept it.
			if v, vok := strconv.parse_u64_maybe_prefixed(value); vok do current.color = u32(v)
		case "contact":
			current.contact = parse_contact_effects(value)
		case "immersion":
			current.immersion = parse_immersion_effects(value)
		case "tags":
			current.tags = parse_reaction_tags(value)
		case "glyph":
			if len(raw) > 0 do current_glyph = raw[0]
		case "decays_to":
			current_decay = value
		case "burns_to":
			current_burn = value
		}
	}

	if has_current {
		append_material(&materials, &names, &glyphs, &decay_names, &burn_names,
		                current, current_name, current_glyph, current_decay, current_burn, allocator)
	}

	table.materials = materials[:]
	table.names     = names[:]
	table.glyphs    = glyphs[:]

	// Resolve the reaction targets now that every name is known.
	// An empty or unknown name falls back to index 0, which is Air.
	for name in decay_names {
		idx, found := find_material_index(table, name)
		append(&decays_to, found ? u16(idx) : 0)
	}
	for name in burn_names {
		idx, found := find_material_index(table, name)
		append(&burns_to, found ? u16(idx) : 0)
	}
	table.decays_to = decays_to[:]
	table.burns_to  = burns_to[:]

	return table, true
}

@(private = "file")
append_material :: proc(
	materials: ^[dynamic]Material, names: ^[dynamic]string, glyphs: ^[dynamic]u8,
	decay_names: ^[dynamic]string, burn_names: ^[dynamic]string,
	m: Material, name: string, glyph: u8, decay: string, burn: string,
	allocator: runtime.Allocator,
) {
	append(materials, m)
	append(names, strings.clone(name, allocator))
	g := glyph
	if g == 0 && len(name) > 0 do g = name[0]
	append(glyphs, g)
	append(decay_names, decay)
	append(burn_names, burn)
}

destroy_material_table :: proc(table: Material_Table, allocator := context.allocator) {
	for n in table.names do delete(n, allocator)
	delete(table.materials, allocator)
	delete(table.names, allocator)
	delete(table.glyphs, allocator)
	delete(table.decays_to, allocator)
	delete(table.burns_to, allocator)
}

parse_contact_effects :: proc(s: string) -> bit_set[Contact_Effect; u32] {
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
		}
	}
	return result
}

parse_immersion_effects :: proc(s: string) -> bit_set[Immersion_Effect; u32] {
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
		}
	}
	return result
}

parse_reaction_tags :: proc(s: string) -> bit_set[Reaction_Tag; u32] {
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
		}
	}
	return result
}

find_material_index :: proc(table: Material_Table, name: string) -> (idx: int, found: bool) {
	if len(name) == 0 do return -1, false
	for n, i in table.names {
		if n == name do return i, true
	}
	return -1, false
}

/*
The material a color stands for, the way find_biome_by_color reads the
biome map.

A tile PNG is painted in material colors, so this turns paint back
into ids. It runs once per pixel at load time over a short table, so a
scan is the right rung: a color index would be more code and no
faster at this size.

Material colors must be unique for this to mean anything. A test on
the shipped table holds that line.
*/
find_material_by_color :: proc(table: Material_Table, color: u32) -> (idx: int, found: bool) {
	for m, i in table.materials {
		if m.color == color do return i, true
	}
	return -1, false
}

// ------------------------------------------------------------
// Data-driven tests (run with: odin test src  from repo root)
// ------------------------------------------------------------

@(test)
test_load_materials_count :: proc(t: ^testing.T) {
	table, ok := load_materials("data/materials.txt")
	defer destroy_material_table(table)
	testing.expect(t, ok, "load must succeed")
	testing.expect(t, len(table.materials) == 12, "expected 12 materials")
	testing.expect(t, len(table.names) == 12, "names must match materials")
	testing.expect(t, len(table.glyphs) == 12, "glyphs must match materials")
	testing.expect(t, len(table.decays_to) == 12, "decay table must match materials")
	testing.expect(t, len(table.burns_to) == 12, "burn table must match materials")
}

@(test)
test_air_is_index_zero :: proc(t: ^testing.T) {
	// The world clears to zeroed memory, so Air must be the first entry.
	table, ok := load_materials("data/materials.txt")
	defer destroy_material_table(table)
	testing.expect(t, ok)

	idx, found := find_material_index(table, "Air")
	testing.expect(t, found, "Air must exist")
	testing.expect(t, idx == 0, "Air must be index 0")
}

@(test)
test_water_properties :: proc(t: ^testing.T) {
	table, ok := load_materials("data/materials.txt")
	defer destroy_material_table(table)
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
	testing.expect(t, table.glyphs[idx] == '~')
}

@(test)
test_acid_effects_and_tags :: proc(t: ^testing.T) {
	table, ok := load_materials("data/materials.txt")
	defer destroy_material_table(table)
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
	defer destroy_material_table(table)
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
test_colors_parse :: proc(t: ^testing.T) {
	table, ok := load_materials("data/materials.txt")
	defer destroy_material_table(table)
	testing.expect(t, ok)

	idx, found := find_material_index(table, "Gold")
	testing.expect(t, found)
	// 0xAARRGGBB. The world view renders this value, so it must survive
	// the 0x prefix in the data file.
	testing.expect(t, table.materials[idx].color == 0xFFFFD700, "Gold color must parse")

	air, air_found := find_material_index(table, "Air")
	testing.expect(t, air_found)
	testing.expect(t, table.materials[air].color == 0x00000000, "Air is transparent")
}

@(test)
test_gold_density :: proc(t: ^testing.T) {
	table, ok := load_materials("data/materials.txt")
	defer destroy_material_table(table)
	testing.expect(t, ok)

	idx, found := find_material_index(table, "Gold")
	testing.expect(t, found)
	m := table.materials[idx]

	testing.expect(t, m.state == .Solid)
	testing.expect(t, m.density == 19.3)
	testing.expect(t, .Metal in m.tags)
	testing.expect(t, m.fall_speed == 0)
}

/*
Tile PNGs are painted in material colors, and the loader reads them
back with find_material_by_color. Two materials sharing one color
would make that lookup pick the wrong one, and the tile would load as
something other than what the author painted.
*/
@(test)
test_material_colors_are_unique :: proc(t: ^testing.T) {
	table, ok := load_materials("data/materials.txt")
	defer destroy_material_table(table)
	testing.expect(t, ok)

	for a, i in table.materials {
		for b, j in table.materials {
			if i == j do continue
			testing.expectf(
				t,
				a.color != b.color,
				"%s and %s share color %08X",
				table.names[i],
				table.names[j],
				a.color,
			)
		}
	}

	// Every color must find its way back to the material it came from.
	for m, i in table.materials {
		idx, found := find_material_by_color(table, m.color)
		testing.expectf(t, found, "%s has a color no lookup finds", table.names[i])
		testing.expectf(t, idx == i, "%s round trips to %s", table.names[i], table.names[idx])
	}
}

@(test)
test_reaction_targets :: proc(t: ^testing.T) {
	table, ok := load_materials("data/materials.txt")
	defer destroy_material_table(table)
	testing.expect(t, ok)

	fire,  _ := find_material_index(table, "Fire")
	smoke, _ := find_material_index(table, "Smoke")
	steam, _ := find_material_index(table, "Steam")
	water, _ := find_material_index(table, "Water")
	oil,   _ := find_material_index(table, "Oil")

	testing.expect(t, int(table.decays_to[fire])  == smoke, "fire must leave smoke")
	testing.expect(t, int(table.decays_to[steam]) == water, "steam must return to water")
	testing.expect(t, int(table.burns_to[oil])    == fire,  "oil must catch fire")
	testing.expect(t, table.decays_to[smoke] == 0, "smoke must fade to air")
	testing.expect(t, table.burns_to[water] == 0, "water must not burn")}
