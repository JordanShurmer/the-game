package game

import "base:runtime"
import "core:fmt"
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

The file also carries one reserved section, `[Reactions]`, read after
every material so a row can name a material defined anywhere in the
file. A row is a pair of materials that meet and both change; see
docs/physics.md.
*/

Material_Table :: struct {
	materials:   []Material, // hot: read every tick
	names:       []string,   // cold: display
	glyphs:      []u8,       // cold: one character for the text map
	decays_to:   []u16,      // cold: material after the lifetime ends
	burns_to:    []u16,      // cold: material after fire reaches it
	crumbles_to: []u16,      // cold: material a blast turns this into

	reactions:   []Reaction, // cold: every row, both ways round
	reaction_at: []i16,      // cold: n*n; the row for a pair, or -1
	reacts:      []bool,     // cold: n; whether this material is in any row
}

// 12 bytes, and the #assert holds it there. A cell that reacts looks
// this up once, so it stays small enough for the lookup to be cheap.
Reaction :: struct {
	a, b:   u16, // what meets
	c, d:   u16, // what it becomes
	chance: u8,  // out of 255, per probe
	_pad:   [3]u8,
}
#assert(size_of(Reaction) == 12)

// A [Reactions] row as written, before the material names are known
// to resolve. Kept on the temp allocator; the strings point into the
// loaded file text, which stays alive until load_materials returns.
@(private = "file")
Raw_Reaction :: struct {
	a, b, c, d: string,
	chance:     u8,
	line:       int, // for the error message if a name does not resolve
}

load_materials :: proc(path: string, allocator := context.allocator) -> (table: Material_Table, ok: bool) {
	data, read_err := os.read_entire_file(path, allocator)
	if read_err != nil {
		return {}, false
	}
	defer delete(data, allocator)

	text := string(data)

	materials   := make([dynamic]Material, allocator)
	names       := make([dynamic]string, allocator)
	glyphs      := make([dynamic]u8, allocator)
	decays_to   := make([dynamic]u16, allocator)
	burns_to    := make([dynamic]u16, allocator)
	crumbles_to := make([dynamic]u16, allocator)
	reactions   := make([dynamic]Reaction, allocator)

	// Names of the reaction targets. They point into `text`, so they
	// stay valid until this procedure returns.
	decay_names    := make([dynamic]string, context.temp_allocator)
	burn_names     := make([dynamic]string, context.temp_allocator)
	crumble_names  := make([dynamic]string, context.temp_allocator)
	reaction_rows  := make([dynamic]Raw_Reaction, context.temp_allocator)

	// Allocated once every material name is known. Zero value is fine
	// to free if the load fails before that point.
	reaction_at: []i16
	reacts:      []bool

	defer if !ok {
		for n in names do delete(n, allocator)
		delete(materials)
		delete(names)
		delete(glyphs)
		delete(decays_to)
		delete(burns_to)
		delete(crumbles_to)
		delete(reactions)
		delete(reaction_at, allocator)
		delete(reacts, allocator)
	}

	current:         Material
	current_name:    string
	current_glyph:   u8
	current_decay:   string
	current_burn:    string
	current_crumble: string
	has_current := false
	in_reactions := false

	line_index := 0
	for line in strings.split_lines_iterator(&text) {
		line_index += 1
		trimmed := strings.trim_space(line)
		if len(trimmed) == 0 || trimmed[0] == '#' do continue

		// New section: a material block, or the reserved [Reactions].
		if trimmed[0] == '[' && trimmed[len(trimmed)-1] == ']' {
			if has_current {
				append_material(&materials, &names, &glyphs, &decay_names, &burn_names, &crumble_names,
				                current, current_name, current_glyph, current_decay, current_burn, current_crumble, allocator)
			}
			section := trimmed[1:len(trimmed)-1]
			if section == "Reactions" {
				in_reactions = true
				has_current  = false
			} else {
				in_reactions    = false
				current_name    = section
				current         = Material{lifetime = -1} // sensible default
				current_glyph   = 0
				current_decay   = ""
				current_burn    = ""
				current_crumble = ""
				has_current     = true
			}
			continue
		}

		if in_reactions {
			row := trimmed
			if idx := strings.index_byte(row, '#'); idx >= 0 {
				row = strings.trim_space(row[:idx])
			}
			if len(row) == 0 do continue

			// A + B -> C + D   chance
			fields: [8]string
			n := 0
			it := row
			for f in strings.fields_iterator(&it) {
				if n < len(fields) do fields[n] = f
				n += 1
			}
			if n != 8 || fields[1] != "+" || fields[3] != "->" || fields[5] != "+" {
				fmt.eprintfln("%s:%d: bad [Reactions] row: %q", path, line_index, trimmed)
				return {}, false
			}
			chance, chance_ok := strconv.parse_uint(fields[7], 10)
			if !chance_ok || chance > 255 {
				fmt.eprintfln("%s:%d: [Reactions] chance must be 0..255: %q", path, line_index, trimmed)
				return {}, false
			}
			append(&reaction_rows, Raw_Reaction{a = fields[0], b = fields[2], c = fields[4], d = fields[6], chance = u8(chance), line = line_index})
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
		case "explosive":
			if v, vok := strconv.parse_uint(value, 10); vok do current.explosive = u8(v)
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
		case "crumbles_to":
			current_crumble = value
		}
	}

	if has_current {
		append_material(&materials, &names, &glyphs, &decay_names, &burn_names, &crumble_names,
		                current, current_name, current_glyph, current_decay, current_burn, current_crumble, allocator)
	}

	table.materials = materials[:]
	table.names     = names[:]
	table.glyphs    = glyphs[:]

	// Resolve the decay, burn and crumble targets now that every name
	// is known. An empty or unknown name falls back to index 0, which
	// is Air: a material with no burns_to just stops existing when it
	// burns, which is a safe default and never a load failure.
	for name in decay_names {
		idx, found := find_material_index(table, name)
		append(&decays_to, found ? u16(idx) : 0)
	}
	for name in burn_names {
		idx, found := find_material_index(table, name)
		append(&burns_to, found ? u16(idx) : 0)
	}
	// crumbles_to is the one of the three that is not gated by another
	// field. A lifetime of -1 stops decays_to being read and a
	// flammability of 0 stops burns_to being read, but a blast asks
	// every cell it touches what it crumbles into. So the default here
	// is the material itself, not Air: "become what you crumble into"
	// is then a no-op for the material that does not crumble, and no
	// caller needs a second field to ask whether it does.
	for name, i in crumble_names {
		idx, found := find_material_index(table, name)
		append(&crumbles_to, found ? u16(idx) : u16(i))
	}
	table.decays_to   = decays_to[:]
	table.burns_to    = burns_to[:]
	table.crumbles_to = crumbles_to[:]

	// A [Reactions] row is authored by hand and names both sides on
	// purpose, unlike decays_to and burns_to which default quietly to
	// Air.
	// A typo here is a silent hole in the table until the day the pair
	// meets in the sandbox, so it fails the load instead.
	n := len(table.materials)
	reaction_at = make([]i16, n * n, allocator)
	for &r in reaction_at do r = -1
	reacts = make([]bool, n, allocator)

	for row in reaction_rows {
		ai, aok := find_material_index(table, row.a)
		bi, bok := find_material_index(table, row.b)
		ci, cok := find_material_index(table, row.c)
		di, dok := find_material_index(table, row.d)
		if !aok || !bok || !cok || !dok {
			bad := row.a
			if aok do bad = row.b
			if aok && bok do bad = row.c
			if aok && bok && cok do bad = row.d
			fmt.eprintfln("%s:%d: [Reactions] names unknown material %q", path, row.line, bad)
			return {}, false
		}

		append(&reactions, Reaction{a = u16(ai), b = u16(bi), c = u16(ci), d = u16(di), chance = row.chance})
		reaction_at[ai * n + bi] = i16(len(reactions) - 1)

		append(&reactions, Reaction{a = u16(bi), b = u16(ai), c = u16(di), d = u16(ci), chance = row.chance})
		reaction_at[bi * n + ai] = i16(len(reactions) - 1)

		reacts[ai] = true
		reacts[bi] = true
	}
	table.reactions   = reactions[:]
	table.reaction_at = reaction_at
	table.reacts      = reacts

	return table, true
}

@(private = "file")
append_material :: proc(
	materials: ^[dynamic]Material, names: ^[dynamic]string, glyphs: ^[dynamic]u8,
	decay_names: ^[dynamic]string, burn_names: ^[dynamic]string, crumble_names: ^[dynamic]string,
	m: Material, name: string, glyph: u8, decay: string, burn: string, crumble: string,
	allocator: runtime.Allocator,
) {
	append(materials, m)
	append(names, strings.clone(name, allocator))
	g := glyph
	if g == 0 && len(name) > 0 do g = name[0]
	append(glyphs, g)
	append(decay_names, decay)
	append(burn_names, burn)
	append(crumble_names, crumble)
}

destroy_material_table :: proc(table: Material_Table, allocator := context.allocator) {
	for n in table.names do delete(n, allocator)
	delete(table.materials, allocator)
	delete(table.names, allocator)
	delete(table.glyphs, allocator)
	delete(table.decays_to, allocator)
	delete(table.burns_to, allocator)
	delete(table.crumbles_to, allocator)
	delete(table.reactions, allocator)
	delete(table.reaction_at, allocator)
	delete(table.reacts, allocator)
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
	// 12 original materials plus the 15 the physics note adds.
	testing.expect(t, len(table.materials) == 27, "expected 27 materials")
	testing.expect(t, len(table.names) == 27, "names must match materials")
	testing.expect(t, len(table.glyphs) == 27, "glyphs must match materials")
	testing.expect(t, len(table.decays_to) == 27, "decay table must match materials")
	testing.expect(t, len(table.burns_to) == 27, "burn table must match materials")
	testing.expect(t, len(table.crumbles_to) == 27, "crumble table must match materials")
	testing.expect(t, len(table.reaction_at) == 27 * 27, "reaction_at must be n*n")
	testing.expect(t, len(table.reacts) == 27, "reacts must match materials")
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
	testing.expect(t, table.burns_to[water] == 0, "water must not burn")
}

@(test)
test_explosive_and_crumbles_to :: proc(t: ^testing.T) {
	table, ok := load_materials("data/materials.txt")
	defer destroy_material_table(table)
	testing.expect(t, ok)

	rock,      _ := find_material_index(table, "Rock")
	gravel,    _ := find_material_index(table, "Gravel")
	gunpowder, _ := find_material_index(table, "Gunpowder")
	tnt,       _ := find_material_index(table, "Tnt")
	water,     _ := find_material_index(table, "Water")

	testing.expect(t, int(table.crumbles_to[rock]) == gravel, "blasted rock must fall as gravel")
	testing.expect(t, int(table.crumbles_to[water]) == water, "water must crumble into itself, so a blast leaves it alone")
	testing.expectf(t, table.materials[gunpowder].explosive > 0, "gunpowder must be explosive")
	testing.expectf(t, table.materials[tnt].explosive > table.materials[gunpowder].explosive,
	                "tnt must hit harder than a single grain of gunpowder")
	testing.expect(t, table.materials[water].explosive == 0, "water must not explode")
}

/*
decays_to and burns_to fall back to Air on an unknown name, and
crumbles_to falls back to the material itself, so a typo in any of
the three does not fail the load: the material just decays into
nothing, or quietly stops crumbling. Either is easy to miss by
reading the table alone. This test re-reads the shipped file and checks every name it
writes by hand, so a typo in data/materials.txt fails here instead of
showing up as a material that quietly vanishes in play.
*/
@(test)
test_shipped_cold_targets_all_resolve :: proc(t: ^testing.T) {
	table, ok := load_materials("data/materials.txt")
	defer destroy_material_table(table)
	testing.expect(t, ok, "the shipped table must load")

	data, read_err := os.read_entire_file("data/materials.txt", context.allocator)
	testing.expect(t, read_err == nil, "must be able to re-read the shipped file")
	defer delete(data)
	text := string(data)

	checked := 0
	for line in strings.split_lines_iterator(&text) {
		trimmed := strings.trim_space(line)
		eq := strings.index_byte(trimmed, '=')
		if eq < 0 do continue
		key := strings.trim_space(trimmed[:eq])
		if key != "decays_to" && key != "burns_to" && key != "crumbles_to" do continue

		value := strings.trim_space(trimmed[eq+1:])
		if idx := strings.index_byte(value, '#'); idx >= 0 {
			value = strings.trim_space(value[:idx])
		}
		if value == "" do continue

		_, found := find_material_index(table, value)
		testing.expectf(t, found, "%s names %q, which no material has", key, value)
		checked += 1
	}
	testing.expect(t, checked > 0, "the shipped file must actually name some targets")

	// A reaction that fails to resolve fails the whole load (checked by
	// test_unknown_material_in_reaction_fails_the_load below), so every
	// row that reached this table already resolved. This just holds
	// that the indices are in range.
	for r in table.reactions {
		testing.expect(t, int(r.a) < len(table.materials) && int(r.b) < len(table.materials))
		testing.expect(t, int(r.c) < len(table.materials) && int(r.d) < len(table.materials))
	}
}

/*
The loader stores a row twice: once as written, once with both sides
and both results swapped. Without this test a reaction could fire
only when the acid cell happens to sit on the `a` side of the pair,
and the other side of every meeting would silently never react.
*/
@(test)
test_reaction_reads_both_ways_round :: proc(t: ^testing.T) {
	table, ok := load_materials("data/materials.txt")
	defer destroy_material_table(table)
	testing.expect(t, ok)

	water,    _ := find_material_index(table, "Water")
	lava,     _ := find_material_index(table, "Lava")
	steam,    _ := find_material_index(table, "Steam")
	obsidian, _ := find_material_index(table, "Obsidian")
	n := len(table.materials)

	forward := table.reaction_at[water*n+lava]
	backward := table.reaction_at[lava*n+water]
	testing.expect(t, forward >= 0, "water meeting lava must react")
	testing.expect(t, backward >= 0, "lava meeting water must react")
	testing.expect(t, forward != backward, "the two directions are different rows")

	fr := table.reactions[int(forward)]
	testing.expect(t, int(fr.a) == water && int(fr.b) == lava)
	testing.expect(t, int(fr.c) == steam && int(fr.d) == obsidian, "water becomes steam, lava becomes obsidian")

	br := table.reactions[int(backward)]
	testing.expect(t, int(br.a) == lava && int(br.b) == water, "the operands are swapped")
	testing.expect(t, int(br.c) == obsidian && int(br.d) == steam, "the results are swapped to match")
	testing.expect(t, br.chance == fr.chance, "the odds do not change with the side you meet it from")
}

@(test)
test_reacts_is_set_only_for_materials_in_a_row :: proc(t: ^testing.T) {
	table, ok := load_materials("data/materials.txt")
	defer destroy_material_table(table)
	testing.expect(t, ok)

	air, _ := find_material_index(table, "Air")
	// Air names no [Reactions] row and touches no cell that does, so
	// the step must never spend a probe on the most common cell.
	testing.expect(t, !table.reacts[air], "air must not react")

	acid, _ := find_material_index(table, "Acid")
	testing.expect(t, table.reacts[acid], "acid has rows in the table")
}

// reaction_at is a dense n*n table. A pair with no row must read -1,
// not 0, or a lookup would mistake "no reaction" for "row zero".
@(test)
test_reaction_at_is_minus_one_for_an_unrelated_pair :: proc(t: ^testing.T) {
	table, ok := load_materials("data/materials.txt")
	defer destroy_material_table(table)
	testing.expect(t, ok)

	gold, _ := find_material_index(table, "Gold")
	dirt, _ := find_material_index(table, "Dirt")
	n := len(table.materials)

	testing.expect(t, table.reaction_at[gold*n+dirt] == -1, "gold and dirt have no reaction")
	testing.expect(t, table.reaction_at[dirt*n+gold] == -1, "neither direction reacts")
}

/*
An unknown name in a [Reactions] row is authoring error, not a
material that just does not react yet. Without this the loader would
default the row to Air like decays_to does, and a typo would sit
silent until the day the pair meets in the sandbox.
*/
@(test)
test_unknown_material_in_reaction_fails_the_load :: proc(t: ^testing.T) {
	body := "[Air]\nstate = Gas\ncolor = 0x00000000\n\n[Rock]\nstate = Solid\ndensity = 2.5\nhardness = 8\ncolor = 0xFF010101\n\n[Reactions]\nRock + Unobtainium -> Air + Air   10\n"
	path := "material_reaction_error_case.tmp.txt"
	testing.expect(t, os.write_entire_file(path, transmute([]byte)body) == nil, "write temp file")
	defer os.remove(path)

	table, ok := load_materials(path)
	testing.expect(t, !ok, "an unknown material in a reaction row must fail the load")
	if ok do destroy_material_table(table)
}
