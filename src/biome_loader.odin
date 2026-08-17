package game

import "base:runtime"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:testing"

/*
Load biomes from the simple text format in data/biomes.txt.

Authoring mistakes are hard errors. A silent default here would show
up much later as a wrong world, so the loader stops at the first bad
line and reports where it is.
*/

Biome_Load_Error :: enum u8 {
	None,
	File_Unreadable,
	Missing_Key,      // a biome has no color or no fill_0
	Duplicate_Color,  // two biomes share one key color
	Unknown_Material, // fill_0 names a material that does not exist
	Unknown_Biome,    // biome_off_map names a biome that does not exist
	Bad_Value,        // a value does not parse
	Too_Many_Biomes,
	Tile_Mismatch,    // generator and the tile key disagree
	Too_Many_Tiles,
}

@(private = "file")
Required_Key :: enum u8 {
	Color,
	Fill_0,
}

@(private = "file")
REQUIRED :: bit_set[Required_Key]{.Color, .Fill_0}

load_biomes :: proc(
	path: string,
	materials: Material_Table,
	allocator := context.allocator,
) -> (
	table: Biome_Table,
	err: Biome_Load_Error,
	line_no: int,
) {
	data, read_err := os.read_entire_file(path, allocator)
	if read_err != nil {
		return {}, .File_Unreadable, 0
	}
	defer delete(data, allocator)

	text := string(data)

	biomes     := make([dynamic]Biome, allocator)
	names      := make([dynamic]string, allocator)
	tile_paths := make([dynamic]string, allocator)

	// The image path, the names, and the tile paths all outlive this
	// proc, so they are cloned. Release them if the load fails part way
	// through.
	map_image_path: string
	ok := false
	defer if !ok {
		for n in names do delete(n, allocator)
		for p in tile_paths do delete(p, allocator)
		delete(map_image_path, allocator)
		delete(biomes)
		delete(names)
		delete(tile_paths)
	}

	table.cells_per_pixel = 512
	table.off_map_biome   = BIOME_EMPTY

	// biome_off_map may name a biome that appears further down the
	// file, so it is resolved after the whole file is read. The slice
	// points into `data`, which is alive until this proc returns.
	off_map_name: string

	in_map_section := false
	has_current    := false
	current:        Biome
	current_name:   string
	current_line:   int
	seen:           bit_set[Required_Key]

	// flush appends the biome being read. It runs at each new section
	// and once more at the end of the file.
	flush :: proc(
		biomes: ^[dynamic]Biome,
		names: ^[dynamic]string,
		current: Biome,
		current_name: string,
		seen: bit_set[Required_Key],
		current_line: int,
		allocator: runtime.Allocator,
	) -> (
		err: Biome_Load_Error,
		line_no: int,
	) {
		if REQUIRED - seen != {} {
			return .Missing_Key, current_line
		}
		// A tile generator needs a tile to draw, and a tile nothing
		// draws is dead authoring. Either mistake shows up as a wrong
		// world much later, so it stops the load here.
		if (current.generator == .Tile) != (current.tile != TILE_NONE) {
			return .Tile_Mismatch, current_line
		}
		for b in biomes {
			if b.key_color == current.key_color {
				return .Duplicate_Color, current_line
			}
		}
		if len(biomes) >= MAX_BIOMES {
			return .Too_Many_Biomes, current_line
		}
		append(biomes, current)
		append(names, strings.clone(current_name, allocator))
		return .None, 0
	}

	line_index := 0
	for raw_line in strings.split_lines_iterator(&text) {
		line_index += 1
		trimmed := strings.trim_space(raw_line)
		if len(trimmed) == 0 || trimmed[0] == '#' do continue

		// New section
		if trimmed[0] == '[' && trimmed[len(trimmed) - 1] == ']' {
			if has_current {
				if e, l := flush(&biomes, &names, current, current_name, seen, current_line, allocator); e != .None {
					return {}, e, l
				}
			}
			section := trimmed[1:len(trimmed) - 1]
			if section == "Map" {
				in_map_section = true
				has_current    = false
			} else {
				in_map_section = false
				// A fresh biome owns no tile. The zero value of Tile_Id is
				// a real tile id, so this must be set, not left blank.
				current        = Biome{tile = TILE_NONE}
				current_name   = section
				current_line   = line_index
				seen           = {}
				has_current    = true
			}
			continue
		}

		// key = value
		eq := strings.index_byte(trimmed, '=')
		if eq < 0 do continue

		key   := strings.trim_space(trimmed[:eq])
		value := strings.trim_space(trimmed[eq + 1:])
		if idx := strings.index_byte(value, '#'); idx >= 0 {
			value = strings.trim_space(value[:idx])
		}

		if in_map_section {
			switch key {
			case "image":
				map_image_path = strings.clone(value, allocator)
			case "cells_per_pixel":
				v, vok := strconv.parse_i64(value)
				if !vok || v <= 0 do return {}, .Bad_Value, line_index
				table.cells_per_pixel = i32(v)
			case "origin_pixel":
				v := value
				xs, xok := strings.fields_iterator(&v)
				ys, yok := strings.fields_iterator(&v)
				if !xok || !yok do return {}, .Bad_Value, line_index
				x, xnum := strconv.parse_i64(xs)
				y, ynum := strconv.parse_i64(ys)
				if !xnum || !ynum do return {}, .Bad_Value, line_index
				table.origin_pixel_x = i32(x)
				table.origin_pixel_y = i32(y)
			case "biome_off_map":
				off_map_name = value
			}
			continue
		}

		if !has_current do continue

		switch key {
		case "color":
			v, vok := strconv.parse_u64_maybe_prefixed(value)
			if !vok do return {}, .Bad_Value, line_index
			current.key_color = u32(v)
			seen += {.Color}
		case "fill_0":
			idx, found := find_material_index(materials, value)
			if !found do return {}, .Unknown_Material, line_index
			current.fill_0 = u16(idx)
			seen += {.Fill_0}
		case "generator":
			switch value {
			case "uniform": current.generator = .Uniform
			case "tile":    current.generator = .Tile
			case:           return {}, .Bad_Value, line_index
			}
		case "tile":
			// Tile ids are handed out in file order and stay dense, so
			// the tile set is one packed block with no holes in it.
			if current.tile != TILE_NONE {
				// The biome named a tile twice. The last one wins.
				delete(tile_paths[current.tile], allocator)
				tile_paths[current.tile] = strings.clone(value, allocator)
			} else {
				if len(tile_paths) >= MAX_TILES do return {}, .Too_Many_Tiles, line_index
				current.tile = Tile_Id(len(tile_paths))
				append(&tile_paths, strings.clone(value, allocator))
			}
		}
	}

	if has_current {
		if e, l := flush(&biomes, &names, current, current_name, seen, current_line, allocator); e != .None {
			return {}, e, l
		}
	}

	table.biomes         = biomes[:]
	table.names          = names[:]
	table.tile_paths     = tile_paths[:]
	table.map_image_path = map_image_path

	if off_map_name != "" {
		idx, found := find_biome_index(table, off_map_name)
		if !found {
			return {}, .Unknown_Biome, 0
		}
		table.off_map_biome = Biome_Id(idx)
	}
	if table.off_map_biome == BIOME_EMPTY {
		return {}, .Unknown_Biome, 0
	}

	ok = true
	return table, .None, 0
}

destroy_biome_table :: proc(table: Biome_Table, allocator := context.allocator) {
	for n in table.names do delete(n, allocator)
	for p in table.tile_paths do delete(p, allocator)
	delete(table.map_image_path, allocator)
	delete(table.biomes, allocator)
	delete(table.names, allocator)
	delete(table.tile_paths, allocator)
}

// ------------------------------------------------------------
// Tests (run with: odin test src  from repo root)
// ------------------------------------------------------------

// load_test_tables loads the real data files. Tests use the shipped
// data so a bad edit to the data breaks the build.
@(private = "file")
load_test_tables :: proc(t: ^testing.T) -> (materials: Material_Table, biomes: Biome_Table, ok: bool) {
	mat_ok: bool
	materials, mat_ok = load_materials("data/materials.txt")
	if !testing.expect(t, mat_ok, "materials must load") {
		return {}, {}, false
	}

	err: Biome_Load_Error
	line: int
	biomes, err, line = load_biomes("data/biomes.txt", materials)
	if !testing.expectf(t, err == .None, "biomes must load, got %v at line %d", err, line) {
		destroy_material_table(materials)
		return {}, {}, false
	}
	return materials, biomes, true
}

@(private = "file")
destroy_test_tables :: proc(materials: Material_Table, biomes: Biome_Table) {
	destroy_biome_table(biomes)
	destroy_material_table(materials)
}

@(test)
test_load_biomes :: proc(t: ^testing.T) {
	materials, biomes, ok := load_test_tables(t)
	if !ok do return
	defer destroy_test_tables(materials, biomes)

	testing.expect(t, len(biomes.biomes) == 9, "expected 9 biomes")
	testing.expect(t, len(biomes.names) == len(biomes.biomes))
	testing.expect(t, biomes.cells_per_pixel == 512)
	testing.expect(t, biomes.origin_pixel_x == 8)
	testing.expect(t, biomes.origin_pixel_y == 8)
	testing.expect(t, biomes.map_image_path == "data/biome_map.png")

	idx, found := find_biome_index(biomes, "Coalmine")
	testing.expect(t, found, "Coalmine must exist")
	testing.expect(t, biomes.biomes[idx].key_color == 0xFFD57917)
	testing.expect(t, biomes.biomes[idx].generator == .Tile)

	dirt, dirt_found := find_material_index(materials, "Dirt")
	testing.expect(t, dirt_found)
	testing.expect(t, int(biomes.biomes[idx].fill_0) == dirt, "a new Coalmine tile starts as Dirt")

	// A tile biome carries a tile id, and that id names a file.
	tile := biomes.biomes[idx].tile
	testing.expect(t, tile != TILE_NONE, "Coalmine must own a tile")
	testing.expect(t, biomes.tile_paths[tile] == "data/tiles/coalmine.png")

	sky, sky_found := find_biome_index(biomes, "Sky")
	testing.expect(t, sky_found)
	testing.expect(t, biomes.biomes[sky].generator == .Uniform)
	testing.expect(t, biomes.biomes[sky].tile == TILE_NONE, "a uniform biome owns no tile")

	off, off_found := find_biome_index(biomes, "Deep_Rock")
	testing.expect(t, off_found)
	testing.expect(t, int(biomes.off_map_biome) == off, "off-map biome resolves by name")
}

/*
Tile ids are dense and unique. The tile set packs its cells by id, so
a repeated id would make two biomes share one tile by accident, and a
gap would waste a block nobody can reach.
*/
@(test)
test_biome_tile_ids_are_dense_and_unique :: proc(t: ^testing.T) {
	materials, biomes, ok := load_test_tables(t)
	if !ok do return
	defer destroy_test_tables(materials, biomes)

	seen := make([]bool, biome_tile_count(biomes))
	defer delete(seen)

	tiles := 0
	for b, i in biomes.biomes {
		if b.tile == TILE_NONE do continue
		tiles += 1
		if !testing.expectf(t, int(b.tile) < len(seen), "%s has tile id %d, out of range", biomes.names[i], b.tile) {
			continue
		}
		testing.expectf(t, !seen[b.tile], "two biomes claim tile id %d", b.tile)
		seen[b.tile] = true
	}

	testing.expect(t, tiles == biome_tile_count(biomes), "every tile path belongs to a biome")
	for used, id in seen {
		testing.expectf(t, used, "tile id %d has no biome", id)
	}
	for p in biomes.tile_paths {
		testing.expect(t, p != "", "every tile names a file")
	}
}

@(test)
test_biome_key_colors_are_unique :: proc(t: ^testing.T) {
	materials, biomes, ok := load_test_tables(t)
	if !ok do return
	defer destroy_test_tables(materials, biomes)

	for a, i in biomes.biomes {
		for b, j in biomes.biomes {
			if i == j do continue
			testing.expectf(
				t,
				a.key_color != b.key_color,
				"%s and %s share key color %08X",
				biomes.names[i],
				biomes.names[j],
				a.key_color,
			)
		}
	}
}

@(test)
test_biome_load_errors :: proc(t: ^testing.T) {
	materials, mat_ok := load_materials("data/materials.txt")
	testing.expect(t, mat_ok)
	defer destroy_material_table(materials)

	Case :: struct {
		name: string,
		body: string,
		want: Biome_Load_Error,
	}

	cases := []Case{
		{
			"duplicate color",
			"[Map]\nbiome_off_map = A\n[A]\ncolor = 0xFF000001\nfill_0 = Rock\n[B]\ncolor = 0xFF000001\nfill_0 = Sand\n",
			.Duplicate_Color,
		},
		{
			"unknown material",
			"[Map]\nbiome_off_map = A\n[A]\ncolor = 0xFF000001\nfill_0 = Unobtainium\n",
			.Unknown_Material,
		},
		{
			"unknown off-map biome",
			"[Map]\nbiome_off_map = Nowhere\n[A]\ncolor = 0xFF000001\nfill_0 = Rock\n",
			.Unknown_Biome,
		},
		{
			"missing fill",
			"[Map]\nbiome_off_map = A\n[A]\ncolor = 0xFF000001\n",
			.Missing_Key,
		},
		{
			"missing color",
			"[Map]\nbiome_off_map = A\n[A]\nfill_0 = Rock\n",
			.Missing_Key,
		},
		{
			"bad generator",
			"[Map]\nbiome_off_map = A\n[A]\ncolor = 0xFF000001\nfill_0 = Rock\ngenerator = wang\n",
			.Bad_Value,
		},
		{
			"tile generator with no tile",
			"[Map]\nbiome_off_map = A\n[A]\ncolor = 0xFF000001\nfill_0 = Rock\ngenerator = tile\n",
			.Tile_Mismatch,
		},
		{
			"tile with no tile generator",
			"[Map]\nbiome_off_map = A\n[A]\ncolor = 0xFF000001\nfill_0 = Rock\ntile = a.png\n",
			.Tile_Mismatch,
		},
		{
			"tile and generator together are fine",
			"[Map]\nbiome_off_map = A\n[A]\ncolor = 0xFF000001\nfill_0 = Rock\ngenerator = tile\ntile = a.png\n",
			.None,
		},
	}

	for c in cases {
		path := "biome_error_case.tmp.txt"
		testing.expect(t, os.write_entire_file(path, transmute([]byte)c.body) == nil, "write temp file")
		defer os.remove(path)

		table, err, _ := load_biomes(path, materials)
		testing.expectf(t, err == c.want, "%s: want %v, got %v", c.name, c.want, err)
		if err == .None do destroy_biome_table(table)
	}
}

@(test)
test_biome_missing_file_is_an_error :: proc(t: ^testing.T) {
	materials, mat_ok := load_materials("data/materials.txt")
	testing.expect(t, mat_ok)
	defer destroy_material_table(materials)

	_, err, _ := load_biomes("data/does_not_exist.txt", materials)
	testing.expect(t, err == .File_Unreadable)
}
