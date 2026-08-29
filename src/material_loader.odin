package game

import "base:runtime"
import "core:strconv"
import "core:strings"
import "core:testing"

Material_Table :: struct {
	materials:   []Material,
	names:       []string,
	glyphs:      []u8,
	decays_to:   []u16,
	burns_to:    []u16,
	crumbles_to: []u16,

	reactions:   []Reaction,
	reaction_at: []i16,
	partners:    []u64,

	weight:      []u16,
	kind:        []Cell_Kind,
	work:        []Cell_Works,
	// The two numbers the step reads a cell at a time, out of the 24
	// byte Material the whole shape of the step was built to keep out
	// of the inner loop. See docs/physics.md, "Where the tick goes now".
	spread:      []u8,
	fall_speed:  []u8,

	weight_lut: [8 * SANDBOX_WIDE_LANES]u8,
	lut_ok:     bool,
	wide_ok:    bool,

	fire:        u16,
	soot:        u16,

	// The lights of the world, and the material a bang is made of.
	// See docs/lighting.md, "Every light is a material".
	blast:       u16,
	orb:         u16,
	crystal:     u16,
	firefly:     u16,
	sparkle:     u16,
}

// next chains to the next row for the same pair, -1 for the end of the
// chain. See docs/alchemy.md, "A chain of rows".
Reaction :: struct {
	c, d:   u16,
	chance: u8,
	next:   i16,
}
#assert(size_of(Reaction) == 8)

@(private = "file")
Raw_Reaction :: struct {
	a, b, c, d: string,
	chance:     u8,
	line:       int,
}

// Walks a chain from its head and returns the last row in it and the sum of
// every chance along the way. -1 in, -1 out, floor 0: an empty chain.
@(private = "file")
reaction_chain_tail :: proc(reactions: []Reaction, head: i16) -> (tail: i16, floor: u32) {
	tail = -1
	at := head
	for at >= 0 {
		floor += u32(reactions[at].chance)
		tail = at
		at = reactions[at].next
	}
	return
}

load_materials :: proc(path: string, allocator := context.allocator) -> (table: Material_Table, ok: bool) {
	data, read_ok := file_read(path, allocator)
	if !read_ok {
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

	decay_names    := make([dynamic]string, context.temp_allocator)
	burn_names     := make([dynamic]string, context.temp_allocator)
	crumble_names  := make([dynamic]string, context.temp_allocator)
	reaction_rows  := make([dynamic]Raw_Reaction, context.temp_allocator)

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
				current         = Material{lifetime = -1}
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

			fields: [8]string
			n := 0
			it := row
			for f in strings.fields_iterator(&it) {
				if n < len(fields) do fields[n] = f
				n += 1
			}
			if n != 8 || fields[1] != "+" || fields[3] != "->" || fields[5] != "+" {
				fault("%s:%d: bad [Reactions] row: %q", path, line_index, trimmed)
				return {}, false
			}
			chance, chance_ok := strconv.parse_uint(fields[7], 10)
			if !chance_ok || chance > 255 {
				fault("%s:%d: [Reactions] chance must be 0..255: %q", path, line_index, trimmed)
				return {}, false
			}
			append(&reaction_rows, Raw_Reaction{a = fields[0], b = fields[2], c = fields[4], d = fields[6], chance = u8(chance), line = line_index})
			continue
		}

		if !has_current do continue

		eq := strings.index_byte(trimmed, '=')
		if eq < 0 do continue

		key := strings.trim_space(trimmed[:eq])
		raw := strings.trim_space(trimmed[eq+1:])
		value := raw
		if idx := strings.index_byte(value, '#'); idx >= 0 {
			value = strings.trim_space(value[:idx])
		}

		switch key {
		case "state":
			switch value {
			case "Solid":   current.state = .Solid
			case "Brush":   current.state = .Brush
			case "Powder":  current.state = .Powder
			case "Liquid":  current.state = .Liquid
			case "Gas":     current.state = .Gas
			case "Special": current.state = .Special
			case "Phantom": current.state = .Phantom
			}
		case "density":
			if v, vok := strconv.parse_f32(value); vok do current.density = v
		case "fall_speed":
			if v, vok := strconv.parse_uint(value, 10); vok do current.fall_speed = u8(v)
		case "hardness":
			if v, vok := strconv.parse_uint(value, 10); vok do current.hardness = u8(v)
		case "flammability":
			if v, vok := strconv.parse_uint(value, 10); vok do current.flammability = u8(v)
		case "force":
			if v, vok := strconv.parse_uint(value, 10); vok do current.force = u8(v)
		case "luminosity":
			if v, vok := strconv.parse_uint(value, 10); vok do current.luminosity = u8(v)
		case "spread":
			if v, vok := strconv.parse_uint(value, 10); vok do current.spread = u8(v)
		case "lifetime":
			if v, vok := strconv.parse_i64(value); vok do current.lifetime = i32(v)
		case "color":
			if v, vok := strconv.parse_u64_maybe_prefixed(value); vok do current.color = u32(v)
		case "contact":
			current.contact = parse_contact_effects(value)
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

	for name in decay_names {
		idx, found := find_material_index(table, name)
		append(&decays_to, found ? u16(idx) : 0)
	}
	for name in burn_names {
		idx, found := find_material_index(table, name)
		append(&burns_to, found ? u16(idx) : 0)
	}
	for name, i in crumble_names {
		idx, found := find_material_index(table, name)
		append(&crumbles_to, found ? u16(idx) : u16(i))
	}
	table.decays_to   = decays_to[:]
	table.burns_to    = burns_to[:]
	table.crumbles_to = crumbles_to[:]

	// A phantom has no physical interaction, so no cell may ever turn into
	// one. Refusing it here, once, is what lets the sandbox trust that
	// every material it holds is matter.
	for i in 0 ..< len(table.materials) {
		products := [3]struct{what: string, to: u16} {
			{"decays_to", table.decays_to[i]},
			{"burns_to", table.burns_to[i]},
			{"crumbles_to", table.crumbles_to[i]},
		}
		for product in products {
			if int(product.to) == i do continue
			if !material_is_phantom(table.materials[product.to]) do continue
			fault(
				"%s: %s %s %s, which has no physical interaction and cannot be in a cell",
				path, table.names[i], product.what, table.names[product.to],
			)
			return {}, false
		}
	}

	if idx, found := find_material_index(table, "Fire"); found {
		table.fire = u16(idx)
	}
	if idx, found := find_material_index(table, "Soot"); found {
		table.soot = u16(idx)
	}
	if idx, found := find_material_index(table, "Blast"); found {
		table.blast = u16(idx)
	}
	if idx, found := find_material_index(table, "Orb_Light"); found {
		table.orb = u16(idx)
	}
	if idx, found := find_material_index(table, "Light_Crystal"); found {
		table.crystal = u16(idx)
	}
	if idx, found := find_material_index(table, "Firefly_Light"); found {
		table.firefly = u16(idx)
	}
	if idx, found := find_material_index(table, "Sparkle"); found {
		table.sparkle = u16(idx)
	}

	n := len(table.materials)
	reaction_at = make([]i16, n * n, allocator)
	for &r in reaction_at do r = -1
	reacts = make([]bool, n, allocator)
	// Only the load needs it: cell_work_of copies the bit into table.work.
	defer delete(reacts, allocator)

	// The line each stored row came from, so a row that can never fire
	// names the row that filled the chain before it. Kept only for the
	// load; not part of the table.
	reaction_line := make([dynamic]int, context.temp_allocator)

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
			fault("%s:%d: [Reactions] names unknown material %q", path, row.line, bad)
			return {}, false
		}

		if material_is_phantom(table.materials[ci]) || material_is_phantom(table.materials[di]) {
			fault(
				"%s:%d: [Reactions] makes %s, which has no physical interaction and cannot be in a cell",
				path, row.line, table.names[material_is_phantom(table.materials[ci]) ? ci : di],
			)
			return {}, false
		}

		// A row after a row that already carries the chain past 255 can
		// never fire. See docs/alchemy.md, "A chain of rows".
		tail_fwd, floor := reaction_chain_tail(reactions[:], reaction_at[ai*n+bi])
		if floor >= 256 {
			fault(
				"%s:%d: [Reactions] row can never fire: the chain from %s:%d already reaches %d of 255",
				path, row.line, path, reaction_line[tail_fwd], floor,
			)
			return {}, false
		}

		idx_fwd := i16(len(reactions))
		append(&reactions, Reaction{c = u16(ci), d = u16(di), chance = row.chance, next = -1})
		append(&reaction_line, row.line)
		if tail_fwd >= 0 {
			reactions[tail_fwd].next = idx_fwd
		} else {
			reaction_at[ai*n + bi] = idx_fwd
		}

		tail_rev, _ := reaction_chain_tail(reactions[:], reaction_at[bi*n+ai])
		idx_rev := i16(len(reactions))
		append(&reactions, Reaction{c = u16(di), d = u16(ci), chance = row.chance, next = -1})
		append(&reaction_line, row.line)
		if tail_rev >= 0 {
			reactions[tail_rev].next = idx_rev
		} else {
			reaction_at[bi*n + ai] = idx_rev
		}

		reacts[ai] = true
		reacts[bi] = true
	}
	table.reactions   = reactions[:]
	table.reaction_at = reaction_at
	table.partners    = reaction_partners(reaction_at, n, allocator)

	table.weight     = make([]u16, n, allocator)
	table.kind       = make([]Cell_Kind, n, allocator)
	table.work       = make([]Cell_Works, n, allocator)
	table.spread     = make([]u8, n, allocator)
	table.fall_speed = make([]u8, n, allocator)
	for &m, i in table.materials {
		is_air := Cell(i) == MATERIAL_AIR
		m.spread = cell_spread_of(m)
		table.weight[i]     = cell_weight_of(m, is_air)
		table.kind[i]       = cell_kind_of(m, is_air)
		table.work[i]       = cell_work_of(m, reacts[i])
		table.spread[i]     = m.spread
		table.fall_speed[i] = m.fall_speed
	}
	sandbox_build_luts(&table)

	return table, true
}

// One bit a partner: bit d of partners[c] says c and d have a row in
// reaction_at, so the sandbox can ask "can these two react at all?"
// without walking the n*n table for every quiet neighbour. A table too
// big for the bits keeps every reacting material at all-ones, so the
// filter passes everything and reaction_at stays the authority.
@(private = "file")
reaction_partners :: proc(reaction_at: []i16, n: int, allocator: runtime.Allocator) -> []u64 {
	partners := make([]u64, n, allocator)
	for c in 0 ..< n {
		for d in 0 ..< n {
			if reaction_at[c*n + d] < 0 do continue
			partners[c] |= n <= 64 ? u64(1) << u64(d) : max(u64)
		}
	}
	return partners
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
	delete(table.partners, allocator)
	delete(table.weight, allocator)
	delete(table.kind, allocator)
	delete(table.work, allocator)
	delete(table.spread, allocator)
	delete(table.fall_speed, allocator)
}

parse_contact_effects :: proc(s: string) -> bit_set[Contact_Effect; u32] {
	result: bit_set[Contact_Effect; u32]
	s := s
	for part in strings.fields_iterator(&s) {
		switch part {
		case "Burns": result += {.Burns}
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

find_material_by_color :: proc(table: Material_Table, color: u32) -> (idx: int, found: bool) {
	for m, i in table.materials {
		if m.color == color do return i, true
	}
	return -1, false
}

@(test)
test_load_materials_count :: proc(t: ^testing.T) {
	table, ok := load_materials("data/materials.txt")
	defer destroy_material_table(table)
	testing.expect(t, ok, "load must succeed")
	testing.expect(t, len(table.materials) == 54, "expected 54 materials")
	testing.expect(t, len(table.names) == 54, "names must match materials")
	testing.expect(t, len(table.glyphs) == 54, "glyphs must match materials")
	testing.expect(t, len(table.decays_to) == 54, "decay table must match materials")
	testing.expect(t, len(table.burns_to) == 54, "burn table must match materials")
	testing.expect(t, len(table.crumbles_to) == 54, "crumble table must match materials")
	testing.expect(t, len(table.reaction_at) == 54 * 54, "reaction_at must be n*n")
	testing.expect(t, len(table.work) == 54, "work must match materials")
}

@(test)
test_soot_and_powder_resolve_to_a_real_material :: proc(t: ^testing.T) {
	table, ok := load_materials("data/materials.txt")
	defer destroy_material_table(table)
	testing.expect(t, ok)

	testing.expectf(
		t, table.soot != u16(MATERIAL_AIR),
		"soot must resolve to a real material, or a blast paints nothing on the walls it cannot break",
	)
	_, powder_found := find_material_index(table, "Gunpowder")
	testing.expect(
		t, powder_found,
		"powder must resolve to a real material, or a pot's potency is always zero",
	)
}

// Every light in the world is a row in the table, and so is the explosion the
// light of a bang comes off. See docs/lighting.md, "Every light is a material".
@(test)
test_every_light_of_the_world_is_a_material :: proc(t: ^testing.T) {
	table, ok := load_materials("data/materials.txt")
	defer destroy_material_table(table)
	if !testing.expect(t, ok, "materials must load") do return

	Case :: struct {
		what:    string,
		at:      u16,
		phantom: bool,
	}
	cases := []Case {
		{"the bang an explosion makes", table.blast, false},
		{"the orb on his staff", table.orb, true},
		{"a crystal of light", table.crystal, true},
		{"a firefly", table.firefly, true},
		{"the sparkle the mix throws off", table.sparkle, false},
	}

	for c in cases {
		if !testing.expectf(t, c.at != u16(MATERIAL_AIR), "%s must be a material of its own", c.what) {
			continue
		}
		m := table.materials[c.at]
		testing.expectf(
			t, m.luminosity > 0,
			"%s must carry a luminosity, and %s carries none", c.what, table.names[c.at],
		)
		testing.expectf(
			t, material_is_phantom(m) == c.phantom,
			"%s: %s is %v and the world needs a phantom of %v",
			c.what, table.names[c.at], m.state, c.phantom,
		)
	}

	testing.expectf(
		t, table.materials[table.orb].lifetime < 0,
		"the orb he carries must not decay, and it lasts %d ticks",
		table.materials[table.orb].lifetime,
	)
	testing.expectf(
		t, table.materials[table.crystal].lifetime < 0,
		"nor may a crystal he leaves, and it lasts %d ticks",
		table.materials[table.crystal].lifetime,
	)
	testing.expectf(
		t, table.materials[table.blast].lifetime > 0,
		"a blast must decay, and it lasts %d ticks",
		table.materials[table.blast].lifetime,
	)
}

// Nothing may turn into a material with no physical interaction, because no
// cell can hold one. The loader is the only place that can say so once.
@(test)
test_the_loader_refuses_a_table_that_turns_matter_into_a_phantom :: proc(t: ^testing.T) {
	path := "materials_phantom.tmp.txt"
	text := `
[Air]
state       = Gas
color       = 0x00000000

[Wisp]
state       = Phantom
color       = 0xFF112233
luminosity  = 200

[Straw]
state       = Solid
color       = 0xFF445566
flammability= 4
burns_to    = Wisp
`
	if !testing.expect(t, file_write(path, transmute([]byte)text), "write temp file") {
		return
	}
	defer file_remove(path)

	table, ok := load_materials(path)
	testing.expect(
		t, !ok,
		"a table where straw burns into a phantom must be refused, because no cell can hold one",
	)
	if ok do destroy_material_table(table)
}

@(test)
test_air_is_index_zero :: proc(t: ^testing.T) {
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
	testing.expect(t, m.lifetime == -1)
	testing.expect(t, table.glyphs[idx] == '~')
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
}

@(test)
test_colors_parse :: proc(t: ^testing.T) {
	table, ok := load_materials("data/materials.txt")
	defer destroy_material_table(table)
	testing.expect(t, ok)

	idx, found := find_material_index(table, "Gold")
	testing.expect(t, found)
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
	testing.expect(t, m.fall_speed == 0)
}

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
test_expulsive_force_and_crumbles_to :: proc(t: ^testing.T) {
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
	testing.expectf(t, table.materials[gunpowder].force > 0, "gunpowder must carry an expulsive force")
	testing.expectf(t, table.materials[tnt].force > table.materials[gunpowder].force,
	                "tnt must hit harder than a single grain of gunpowder")
	testing.expect(t, table.materials[water].force == 0, "water must not explode")
	testing.expectf(t, table.materials[table.blast].force > 0,
	                "the material an explosion is made of must carry an expulsive force of its own")
}

@(test)
test_shipped_cold_targets_all_resolve :: proc(t: ^testing.T) {
	table, ok := load_materials("data/materials.txt")
	defer destroy_material_table(table)
	testing.expect(t, ok, "the shipped table must load")

	data, read_ok := file_read("data/materials.txt", context.allocator)
	testing.expect(t, read_ok, "must be able to re-read the shipped file")
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

	for r in table.reactions {
		testing.expect(t, int(r.c) < len(table.materials) && int(r.d) < len(table.materials))
	}
}

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
	testing.expect(t, int(fr.c) == steam && int(fr.d) == obsidian, "water becomes steam, lava becomes obsidian")

	br := table.reactions[int(backward)]
	testing.expect(t, int(br.c) == obsidian && int(br.d) == steam, "the results are swapped to match")
	testing.expect(t, br.chance == fr.chance, "the odds do not change with the side you meet it from")
}

@(test)
test_reacts_is_set_only_for_materials_in_a_row :: proc(t: ^testing.T) {
	table, ok := load_materials("data/materials.txt")
	defer destroy_material_table(table)
	testing.expect(t, ok)

	air, _ := find_material_index(table, "Air")
	testing.expect(t, .Reacts not_in table.work[air], "air must not react")

	acid, _ := find_material_index(table, "Acid")
	testing.expect(t, .Reacts in table.work[acid], "acid has rows in the table")
}

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

@(test)
test_unknown_material_in_reaction_fails_the_load :: proc(t: ^testing.T) {
	body := "[Air]\nstate = Gas\ncolor = 0x00000000\n\n[Rock]\nstate = Solid\ndensity = 2.5\nhardness = 8\ncolor = 0xFF010101\n\n[Reactions]\nRock + Unobtainium -> Air + Air   10\n"
	path := "material_reaction_error_case.tmp.txt"
	testing.expect(t, file_write(path, transmute([]byte)body), "write temp file")
	defer file_remove(path)

	table, ok := load_materials(path)
	testing.expect(t, !ok, "an unknown material in a reaction row must fail the load")
	if ok do destroy_material_table(table)
}

@(private = "file")
CHAIN_MATERIALS :: `
[Air]
state = Gas
color = 0x00000000

[A]
state = Solid
color = 0xFF010101

[B]
state = Solid
color = 0xFF020202

[C]
state = Solid
color = 0xFF030303

[D]
state = Solid
color = 0xFF040404
`

// A pair may name as many rows as it likes, tried in the order written, and
// the roll is one per pair. See docs/alchemy.md, "A chain of rows".
@(test)
test_reaction_rows_chain_in_the_order_they_are_written :: proc(t: ^testing.T) {
	body := CHAIN_MATERIALS + "\n[Reactions]\nA + B -> C + C   100\nA + B -> D + D    50\n"
	path := "material_chain_case.tmp.txt"
	testing.expect(t, file_write(path, transmute([]byte)body), "write temp file")
	defer file_remove(path)

	table, ok := load_materials(path)
	defer destroy_material_table(table)
	if !testing.expect(t, ok, "a chain of two rows must load") do return

	a, _ := find_material_index(table, "A")
	b, _ := find_material_index(table, "B")
	c, _ := find_material_index(table, "C")
	d, _ := find_material_index(table, "D")
	n := len(table.materials)

	head := table.reaction_at[a*n+b]
	if !testing.expect(t, head >= 0, "the pair must react") do return

	first := table.reactions[head]
	testing.expect(t, first.chance == 100 && int(first.c) == c, "the first row written must be tried first")
	testing.expect(t, first.next >= 0, "the first row must chain to the second")

	second := table.reactions[first.next]
	testing.expect(t, second.chance == 50 && int(second.c) == d, "the second row written must come second")
	testing.expect(t, second.next == -1, "the chain must end after the last row written")

	rhead := table.reaction_at[b*n+a]
	rfirst := table.reactions[rhead]
	testing.expect(t, rfirst.chance == 100 && int(rfirst.d) == c, "the reverse chain must carry the same order")
	rsecond := table.reactions[rfirst.next]
	testing.expect(t, rsecond.chance == 50 && int(rsecond.d) == d)
	testing.expect(t, rsecond.next == -1)
}

// A single row must behave exactly as it did before the chain existed: it
// is its own whole chain, and the chain ends after it.
@(test)
test_a_single_reaction_row_is_its_own_whole_chain :: proc(t: ^testing.T) {
	table, ok := load_materials("data/materials.txt")
	defer destroy_material_table(table)
	if !testing.expect(t, ok, "materials must load") do return

	water, _ := find_material_index(table, "Water")
	lava, _ := find_material_index(table, "Lava")
	n := len(table.materials)

	forward := table.reactions[table.reaction_at[water*n+lava]]
	testing.expect(t, forward.next == -1, "a single row has no next row to chain to")
}

// A row after a row that already carries the chain past 255 can never
// fire. The loader refuses it rather than keeping a silent dead row.
@(test)
test_the_loader_refuses_a_chain_row_that_can_never_fire :: proc(t: ^testing.T) {
	// The first two rows already carry the chain to 300, past 255, so no
	// roll can ever be left over for the third.
	body := CHAIN_MATERIALS + "\n[Reactions]\nA + B -> C + C   200\nA + B -> D + D   100\nA + B -> C + D    10\n"
	path := "material_chain_overflow_case.tmp.txt"
	testing.expect(t, file_write(path, transmute([]byte)body), "write temp file")
	defer file_remove(path)

	table, ok := load_materials(path)
	testing.expect(
		t, !ok,
		"a row after rows that already carry the chain past 255 must be refused",
	)
	if ok do destroy_material_table(table)
}
