package game

import "core:fmt"
import "core:image"
import "core:image/png"
import "core:os"
import "core:strconv"
import "core:strings"

load_world :: proc(
	materials_path: string,
	biomes_path: string,
	allocator := context.allocator,
) -> (world: World, err: Config_Error, ok: bool) {
	mats, merr, mok := load_materials(materials_path, allocator)
	if !mok {
		return {}, merr, false
	}

	data, read_ok := os.read_entire_file(biomes_path, allocator)
	if !read_ok {
		destroy_material_table(mats, allocator)
		return {}, Config_Error{biomes_path, 0, "", "could not read file"}, false
	}
	defer delete(data, allocator)

	sections, tok_err, tok_ok := tokenize_config(string(data), biomes_path, allocator)
	if !tok_ok {
		destroy_material_table(mats, allocator)
		return {}, tok_err, false
	}
	defer free_config_sections(sections, allocator)

	world.materials = mats

	map_sec: Config_Section
	has_map := false
	biome_secs: [dynamic]Config_Section

	for sec in sections {
		if sec.name == "Map" {
			if has_map {
				destroy_world(&world, allocator)
				return {}, Config_Error{biomes_path, sec.line, sec.name, "duplicate [Map] section"}, false
			}
			map_sec = sec
			has_map = true
		} else {
			append(&biome_secs, sec)
		}
	}
	defer delete(biome_secs)

	if !has_map {
		destroy_world(&world, allocator)
		return {}, Config_Error{biomes_path, 0, "", "missing [Map] section"}, false
	}

	biomes := make([dynamic]Biome, allocator)
	defer if !ok {
		for b in biomes do delete(b.name, allocator)
		delete(biomes)
	}

	seen_names: map[string]bool
	seen_colors: map[u32]bool
	defer {
		delete(seen_names)
		delete(seen_colors)
	}

	for sec in biome_secs {
		if seen_names[sec.name] {
			destroy_world(&world, allocator)
			return {}, Config_Error{biomes_path, sec.line, sec.name, "duplicate biome name"}, false
		}
		seen_names[sec.name] = true

		b := Biome{name = strings.clone(sec.name, allocator), generator = .Uniform}
		has_color := false
		has_gen := false
		has_fill := false

		for kv in sec.kvs {
			switch kv.key {
			case "color":
				v, vok := parse_hex_u32(kv.value)
				if !vok {
					destroy_world(&world, allocator)
					return {}, Config_Error{biomes_path, kv.line, kv.value, "bad color"}, false
				}
				if seen_colors[v] {
					destroy_world(&world, allocator)
					return {}, Config_Error{biomes_path, kv.line, kv.value, "duplicate biome key color"}, false
				}
				seen_colors[v] = true
				b.color = v
				has_color = true
			case "generator":
				switch kv.value {
				case "uniform": b.generator = .Uniform
				case "wang", "noise":
					destroy_world(&world, allocator)
					return {}, Config_Error{biomes_path, kv.line, kv.value, "generator not implemented in Slice 1"}, false
				case:
					destroy_world(&world, allocator)
					return {}, Config_Error{biomes_path, kv.line, kv.value, "unknown generator"}, false
				}
				has_gen = true
			case "fill_0":
				id, found := find_material_id(world.materials, kv.value)
				if !found {
					destroy_world(&world, allocator)
					return {}, Config_Error{biomes_path, kv.line, kv.value, "unknown material"}, false
				}
				b.fill_0 = id
				has_fill = true
			case "tileset":
			case:
				destroy_world(&world, allocator)
				return {}, Config_Error{biomes_path, kv.line, kv.key, "unknown key"}, false
			}
		}

		if !has_color || !has_gen || !has_fill {
			destroy_world(&world, allocator)
			return {}, Config_Error{biomes_path, sec.line, sec.name, "biome missing color, generator, or fill_0"}, false
		}
		append(&biomes, b)
	}

	if len(biomes) == 0 {
		destroy_world(&world, allocator)
		return {}, Config_Error{biomes_path, 0, "", "no biomes defined"}, false
	}

	image_path: string
	origin: [2]i32
	has_origin := false
	cells_per_pixel: i32 = 512
	off_map_name: string
	above_name: string
	has_off := false
	has_above := false

	for kv in map_sec.kvs {
		switch kv.key {
		case "image": image_path = kv.value
		case "origin_pixel":
			parts := strings.fields(kv.value)
			if len(parts) != 2 {
				destroy_world(&world, allocator)
				return {}, Config_Error{biomes_path, kv.line, kv.value, "origin_pixel needs two integers"}, false
			}
			x, xok := strconv.parse_i64(parts[0])
			y, yok := strconv.parse_i64(parts[1])
			if !xok || !yok {
				destroy_world(&world, allocator)
				return {}, Config_Error{biomes_path, kv.line, kv.value, "bad origin_pixel"}, false
			}
			origin = {i32(x), i32(y)}
			has_origin = true
		case "cells_per_pixel":
			v, vok := strconv.parse_i64(kv.value)
			if !vok || v < 1 {
				destroy_world(&world, allocator)
				return {}, Config_Error{biomes_path, kv.line, kv.value, "bad cells_per_pixel"}, false
			}
			cells_per_pixel = i32(v)
		case "biome_off_map":
			off_map_name = kv.value
			has_off = true
		case "biome_above":
			above_name = kv.value
			has_above = true
		case:
			destroy_world(&world, allocator)
			return {}, Config_Error{biomes_path, kv.line, kv.key, "unknown [Map] key"}, false
		}
	}

	if len(image_path) == 0 || !has_origin || !has_off {
		destroy_world(&world, allocator)
		return {}, Config_Error{biomes_path, map_sec.line, "Map", "missing image, origin_pixel, or biome_off_map"}, false
	}

	find_biome_index :: proc(biomes: []Biome, name: string) -> (int, bool) {
		for b, i in biomes {
			if b.name == name do return i, true
		}
		return -1, false
	}

	off_idx, off_ok := find_biome_index(biomes[:], off_map_name)
	if !off_ok {
		destroy_world(&world, allocator)
		return {}, Config_Error{biomes_path, 0, off_map_name, "biome_off_map names unknown biome"}, false
	}
	above_idx := -1
	if has_above {
		ai, aok := find_biome_index(biomes[:], above_name)
		if !aok {
			destroy_world(&world, allocator)
			return {}, Config_Error{biomes_path, 0, above_name, "biome_above names unknown biome"}, false
		}
		above_idx = ai
	}

	if !ensure_default_biome_map(image_path) {
		destroy_world(&world, allocator)
		return {}, Config_Error{image_path, 0, "", "could not create default biome map"}, false
	}
	img_data, img_ok := os.read_entire_file(image_path, allocator)
	if !img_ok {
		destroy_world(&world, allocator)
		return {}, Config_Error{image_path, 0, "", "could not read biome map image"}, false
	}
	defer delete(img_data, allocator)

	img, img_err := png.load_from_bytes(img_data, allocator = allocator)
	if img_err != nil {
		destroy_world(&world, allocator)
		return {}, Config_Error{image_path, 0, "", "failed to decode PNG"}, false
	}
	defer image.destroy(img)

	if img.width < 1 || img.height < 1 {
		destroy_world(&world, allocator)
		return {}, Config_Error{image_path, 0, "", "biome map is empty"}, false
	}

	pixels := make([]u32, img.width * img.height, allocator)
	channels := int(img.channels)
	if channels < 3 {
		destroy_world(&world, allocator)
		delete(pixels, allocator)
		return {}, Config_Error{image_path, 0, "", "biome map needs at least RGB channels"}, false
	}
	buf := img.pixels.buf[:]
	pixel_count := img.width * img.height
	if len(buf) < pixel_count * channels {
		destroy_world(&world, allocator)
		delete(pixels, allocator)
		return {}, Config_Error{image_path, 0, "", "biome map pixel buffer too small"}, false
	}
	for i in 0 ..< pixel_count {
		base := i * channels
		r := buf[base + 0]
		g := buf[base + 1]
		b := buf[base + 2]
		a: u8 = 255
		if channels >= 4 do a = buf[base + 3]
		pixels[i] = (u32(a) << 24) | (u32(r) << 16) | (u32(g) << 8) | u32(b)
	}

	for py in 0 ..< img.height {
		for px in 0 ..< img.width {
			c := pixels[py * img.width + px]
			found := false
			for b in biomes {
				if b.color == c {
					found = true
					break
				}
			}
			if !found {
				destroy_world(&world, allocator)
				delete(pixels, allocator)
				return {}, Config_Error{image_path, 0, "", fmt.tprintf("unmatched map pixel at (%d,%d) color 0x%08X", px, py, c)}, false
			}
		}
	}

	world.biomes = biomes[:]
	world.map = Biome_Map{
		pixels          = pixels,
		width           = img.width,
		height          = img.height,
		origin_pixel    = origin,
		cells_per_pixel = cells_per_pixel,
		biome_off_map   = off_idx,
		biome_above     = above_idx,
		image_path      = strings.clone(image_path, allocator),
	}
	return world, {}, true
}
