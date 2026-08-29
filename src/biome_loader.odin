package game

import "base:runtime"
import "core:strconv"
import "core:strings"
import "core:testing"

Biome_Load_Error :: enum u8 {
	None,
	File_Unreadable,
	Missing_Key,
	Duplicate_Color,
	Unknown_Material,
	Unknown_Biome,
	Bad_Value,
	Too_Many_Biomes,
	Tile_Mismatch,
	Too_Many_Tiles,
	Region_Mismatch,
	Image_Mismatch,
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
	data, read_ok := file_read(path, allocator)
	if !read_ok {
		return {}, .File_Unreadable, 0
	}
	defer delete(data, allocator)

	text := string(data)

	biomes      := make([dynamic]Biome, allocator)
	names       := make([dynamic]string, allocator)
	prefixes    := make([dynamic]string, allocator)
	image_paths := make([dynamic]string, allocator)

	map_image_path: string
	ok := false
	defer if !ok {
		for n in names do delete(n, allocator)
		for p in prefixes do delete(p, allocator)
		for p in image_paths do delete(p, allocator)
		delete(map_image_path, allocator)
		delete(biomes)
		delete(names)
		delete(prefixes)
		delete(image_paths)
	}

	table.cells_per_pixel = 512
	table.world_seed      = 1
	table.off_map_biome   = BIOME_EMPTY
	table.spawn_biome     = BIOME_EMPTY
	table.spawn_region    = 1

	off_map_name: string
	spawn_name: string

	next_tile := 0

	in_map_section := false
	has_current    := false
	current:        Biome
	current_name:   string
	current_prefix: string
	current_image:  string
	current_line:   int
	seen:           bit_set[Required_Key]

	flush :: proc(
		biomes: ^[dynamic]Biome,
		names: ^[dynamic]string,
		prefixes: ^[dynamic]string,
		image_paths: ^[dynamic]string,
		next_tile: ^int,
		current: Biome,
		current_name: string,
		current_prefix: string,
		current_image: string,
		seen: bit_set[Required_Key],
		current_line: int,
		allocator: runtime.Allocator,
	) -> (
		err: Biome_Load_Error,
		line_no: int,
	) {
		biome := current

		if REQUIRED - seen != {} {
			return .Missing_Key, current_line
		}
		if (biome.generator == .Wang) != (current_prefix != "") {
			return .Tile_Mismatch, current_line
		}
		if (biome.generator == .Image) != (current_image != "") {
			return .Image_Mismatch, current_line
		}
		switch biome.generator {
		case .Wang:    if int(biome.variants) > WANG_MAX_VARIANTS do return .Bad_Value, current_line
		case .Image:   if int(biome.variants) > IMAGE_MAX_VARIANTS do return .Bad_Value, current_line
		case .Uniform: if biome.variants != 1 do return .Bad_Value, current_line
		}
		for b in biomes {
			if b.key_color == biome.key_color {
				return .Duplicate_Color, current_line
			}
		}
		if len(biomes) >= MAX_BIOMES {
			return .Too_Many_Biomes, current_line
		}

		if biome.generator == .Wang {
			biome.tile_base = Tile_Id(next_tile^)
			next_tile^ += WANG_SIGNATURES * int(biome.variants)
			if next_tile^ > MAX_TILES {
				return .Too_Many_Tiles, current_line
			}
		} else {
			biome.tile_base = TILE_NONE
		}

		append(biomes, biome)
		append(names, strings.clone(current_name, allocator))
		append(prefixes, strings.clone(current_prefix, allocator))
		append(image_paths, strings.clone(current_image, allocator))
		return .None, 0
	}

	line_index := 0
	for raw_line in strings.split_lines_iterator(&text) {
		line_index += 1
		trimmed := strings.trim_space(raw_line)
		if len(trimmed) == 0 || trimmed[0] == '#' do continue

		if trimmed[0] == '[' && trimmed[len(trimmed) - 1] == ']' {
			if has_current {
				if e, l := flush(&biomes, &names, &prefixes, &image_paths, &next_tile, current, current_name, current_prefix, current_image, seen, current_line, allocator); e != .None {
					return {}, e, l
				}
			}
			section := trimmed[1:len(trimmed) - 1]
			if section == "Map" {
				in_map_section = true
				has_current    = false
			} else {
				in_map_section = false
				current        = Biome{tile_base = TILE_NONE, variants = 1}
				current_name   = section
				current_prefix = ""
				current_image  = ""
				current_line   = line_index
				seen           = {}
				has_current    = true
			}
			continue
		}

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
				if v % TILE_SIZE != 0 do return {}, .Region_Mismatch, line_index
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
			case "seed":
				v, vok := strconv.parse_u64_maybe_prefixed(value)
				if !vok do return {}, .Bad_Value, line_index
				table.world_seed = v
			case "biome_off_map":
				off_map_name = value
			case "spawn_biome":
				spawn_name = value
			case "spawn_region":
				v, vok := strconv.parse_i64(value)
				if !vok || v < 1 do return {}, .Bad_Value, line_index
				table.spawn_region = i32(v)
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
			case "wang":    current.generator = .Wang
			case "image":   current.generator = .Image
			case:           return {}, .Bad_Value, line_index
			}
		case "tiles":
			if value == "" do return {}, .Bad_Value, line_index
			current_prefix = value
		case "variants":
			v, vok := strconv.parse_i64(value)
			if !vok || v < 1 || v > 255 do return {}, .Bad_Value, line_index
			current.variants = u8(v)
		case "image":
			if value == "" do return {}, .Bad_Value, line_index
			current_image = value
		case "light":
			idx, found := find_material_index(materials, value)
			if !found do return {}, .Unknown_Material, line_index
			current.light = u16(idx)
		}
	}

	if has_current {
		if e, l := flush(&biomes, &names, &prefixes, &image_paths, &next_tile, current, current_name, current_prefix, current_image, seen, current_line, allocator); e != .None {
			return {}, e, l
		}
	}

	table.biomes         = biomes[:]
	table.names          = names[:]
	table.tile_prefixes  = prefixes[:]
	table.image_paths    = image_paths[:]
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
	if spawn_name != "" {
		idx, found := find_biome_index(table, spawn_name)
		if !found {
			return {}, .Unknown_Biome, 0
		}
		table.spawn_biome = Biome_Id(idx)
	}

	ok = true
	return table, .None, 0
}

destroy_biome_table :: proc(table: Biome_Table, allocator := context.allocator) {
	for n in table.names do delete(n, allocator)
	for p in table.tile_prefixes do delete(p, allocator)
	for p in table.image_paths do delete(p, allocator)
	delete(table.map_image_path, allocator)
	delete(table.biomes, allocator)
	delete(table.names, allocator)
	delete(table.tile_prefixes, allocator)
	delete(table.image_paths, allocator)
}

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

	testing.expect(t, len(biomes.biomes) == 13, "expected 13 biomes")
	testing.expect(t, len(biomes.names) == len(biomes.biomes))
	testing.expect(t, len(biomes.tile_prefixes) == len(biomes.biomes))
	testing.expect(t, len(biomes.image_paths) == len(biomes.biomes))
	testing.expect(t, biomes.cells_per_pixel == 512)
	testing.expect(t, biomes.cells_per_pixel % TILE_SIZE == 0, "a region is a whole number of tiles")
	testing.expect(t, biomes.origin_pixel_x == 8)
	testing.expect(t, biomes.origin_pixel_y == 8)
	testing.expect(t, biomes.map_image_path == "data/biome_map.png")
	testing.expect(t, biomes.world_seed != 0, "the lattice needs a seed")

	idx, found := find_biome_index(biomes, "Coalmine")
	testing.expect(t, found, "Coalmine must exist")
	testing.expect(t, biomes.biomes[idx].key_color == 0xFFD57917)
	testing.expect(t, biomes.biomes[idx].generator == .Wang)

	dirt, dirt_found := find_material_index(materials, "Dirt")
	testing.expect(t, dirt_found)
	testing.expect(t, int(biomes.biomes[idx].fill_0) == dirt, "a new Coalmine tile starts as Dirt")

	b := biomes.biomes[idx]
	testing.expect(t, b.tile_base != TILE_NONE, "Coalmine must own a set")
	testing.expect(t, b.variants >= 1)
	testing.expect(t, wang_set_size(b) == WANG_SIGNATURES * int(b.variants))
	testing.expect(t, biomes.tile_prefixes[idx] == "data/tiles/coalmine")
	testing.expect(
		t,
		biome_tile_path(biomes, Biome_Id(idx), wang_tile_id(b, wang_signature(1, 0, 1, 0), 0)) ==
		"data/tiles/coalmine_1010_0.png",
		"the file name must carry the edge colors",
	)

	sky, sky_found := find_biome_index(biomes, "Sky")
	testing.expect(t, sky_found)
	testing.expect(t, biomes.biomes[sky].generator == .Uniform)
	testing.expect(t, biomes.biomes[sky].tile_base == TILE_NONE, "a uniform biome owns no tiles")
	testing.expect(t, biomes.tile_prefixes[sky] == "")

	off, off_found := find_biome_index(biomes, "Deep_Rock")
	testing.expect(t, off_found)
	testing.expect(t, int(biomes.off_map_biome) == off, "off-map biome resolves by name")
}

@(test)
test_biome_tile_ids_are_dense_and_do_not_overlap :: proc(t: ^testing.T) {
	materials, biomes, ok := load_test_tables(t)
	if !ok do return
	defer destroy_test_tables(materials, biomes)

	owner := make([]int, biome_tile_count(biomes))
	defer delete(owner)
	for &o in owner do o = -1

	for b, i in biomes.biomes {
		if b.tile_base == TILE_NONE {
			testing.expectf(t, biomes.tile_prefixes[i] == "", "%s names files it never draws", biomes.names[i])
			continue
		}
		testing.expectf(t, biomes.tile_prefixes[i] != "", "%s owns tiles but names no files", biomes.names[i])

		for k in 0 ..< wang_set_size(b) {
			id := int(b.tile_base) + k
			if !testing.expectf(t, id < len(owner), "%s reaches tile %d, past the end", biomes.names[i], id) {
				continue
			}
			testing.expectf(t, owner[id] < 0, "biomes %d and %d both claim tile %d", owner[id], i, id)
			owner[id] = i
		}
	}

	for who, id in owner {
		testing.expectf(t, who >= 0, "tile id %d has no biome", id)
		found_biome, found := biome_of_tile(biomes, Tile_Id(id))
		testing.expect(t, found && int(found_biome) == who, "the owner lookup must agree")
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
			"[Map]\nbiome_off_map = A\n[A]\ncolor = 0xFF000001\nfill_0 = Rock\ngenerator = herringbone\n",
			.Bad_Value,
		},
		{
			"wang generator with no tiles",
			"[Map]\nbiome_off_map = A\n[A]\ncolor = 0xFF000001\nfill_0 = Rock\ngenerator = wang\n",
			.Tile_Mismatch,
		},
		{
			"tiles with no wang generator",
			"[Map]\nbiome_off_map = A\n[A]\ncolor = 0xFF000001\nfill_0 = Rock\ntiles = data/tiles/a\n",
			.Tile_Mismatch,
		},
		{
			"image with no image generator",
			"[Map]\nbiome_off_map = A\n[A]\ncolor = 0xFF000001\nfill_0 = Rock\nimage = data/rooms/a.png\n",
			.Image_Mismatch,
		},
		{
			"image generator with no image",
			"[Map]\nbiome_off_map = A\n[A]\ncolor = 0xFF000001\nfill_0 = Rock\ngenerator = image\n",
			.Image_Mismatch,
		},
		{
			"image generator with tiles",
			"[Map]\nbiome_off_map = A\n[A]\ncolor = 0xFF000001\nfill_0 = Rock\ngenerator = image\nimage = data/rooms/a.png\ntiles = data/tiles/a\n",
			.Tile_Mismatch,
		},
		{
			"variants out of range",
			"[Map]\nbiome_off_map = A\n[A]\ncolor = 0xFF000001\nfill_0 = Rock\ngenerator = wang\ntiles = a\nvariants = 0\n",
			.Bad_Value,
		},
		{
			"a region that is not a whole number of tiles",
			"[Map]\nbiome_off_map = A\ncells_per_pixel = 500\n[A]\ncolor = 0xFF000001\nfill_0 = Rock\n",
			.Region_Mismatch,
		},
		{
			"tiles and generator together are fine",
			"[Map]\nbiome_off_map = A\n[A]\ncolor = 0xFF000001\nfill_0 = Rock\ngenerator = wang\ntiles = a\nvariants = 3\n",
			.None,
		},
	}

	for c in cases {
		path := "biome_error_case.tmp.txt"
		testing.expect(t, file_write(path, transmute([]byte)c.body), "write temp file")
		defer file_remove(path)

		table, err, _ := load_biomes(path, materials)
		testing.expectf(t, err == c.want, "%s: want %v, got %v", c.name, c.want, err)
		if err == .None {
			testing.expect(t, table.biomes[0].variants == 3, "the set must hold the variants it asked for")
			testing.expect(t, wang_set_size(table.biomes[0]) == WANG_SIGNATURES * 3)
			destroy_biome_table(table)
		}
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
