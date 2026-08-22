package game

// A shader for every material.
//
// The world draws as one texture of flat cell colours. This pass paints
// over it, one material at a time, so a cell of gold reads as metal and a
// cell of rock reads as stone. See docs/material_shaders.md.
//
// Each material may bring one file, `data/shaders/materials/<name>.fs`,
// which holds a single procedure:
//
//     vec3 shade(Surf s) { ... }
//
// The game builds the whole program from three parts: the prelude, which
// declares the uniforms and the helpers and the `Surf` the shader reads;
// the material's own file; and the epilogue, which fills a `Surf` and
// calls `shade`. A material file therefore holds only what makes that
// material look like itself.
//
// The pass reads a g-buffer the game fills beside the pixels: one texel
// per view cell, holding the material there, the light on it, and how
// many cells of the same material stand directly above it. Everything
// else a shader wants (the surface normal, where the light comes from,
// how deep in the body of the material the cell lies) the prelude reads
// out of that buffer.

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import rl "vendor:raylib"

MATERIAL_SHADER_DIR :: "data/shaders/materials"
MATERIAL_SHADER_PRELUDE :: MATERIAL_SHADER_DIR + "/_prelude.glsl"
MATERIAL_SHADER_MAIN :: MATERIAL_SHADER_DIR + "/_main.glsl"

// The deepest a cell can say it is under the surface of its own body.
MATERIAL_DEEPEST :: 255

Material_Uniform :: enum u8 {
	Gbuf,
	Size,
	Origin,
	Step,
	Seconds,
	Id,
}

material_uniform_name := [Material_Uniform]cstring {
	.Gbuf    = "gbuf",
	.Size    = "size",
	.Origin  = "origin",
	.Step    = "step_cells",
	.Seconds = "seconds",
	.Id      = "id",
}

Material_Shader :: struct {
	shader: rl.Shader,
	at:     [Material_Uniform]i32,
	cell:   Cell,
	name:   string,
}

Material_Shaders :: struct {
	list:    []Material_Shader,
	gbuf:    []u8, // four bytes a texel: material, light, depth, the raw light
	texture: rl.Texture2D,
	run:     []u8, // a column each: how far the run of one material reaches
	above:   []Cell, // a column each: what the cell above holds
	seen:    [256]bool,
	on:      bool,
}

// The name of the file a material brings, which is its own name in
// lower case: `Burning_Wood` reads `burning_wood.fs`.
material_shader_path :: proc(name: string, allocator := context.allocator) -> string {
	lower := strings.to_lower(name, allocator)
	defer delete(lower, allocator)
	return strings.concatenate({MATERIAL_SHADER_DIR, "/", lower, ".fs"}, allocator)
}

// The whole program: the prelude, the material, and the epilogue. Kept
// apart from the loading so a test can read it without a window.
material_shader_source :: proc(
	prelude, body, epilogue: string,
	allocator := context.allocator,
) -> string {
	return strings.concatenate({prelude, "\n", body, "\n", epilogue, "\n"}, allocator)
}

material_shaders_load :: proc(
	materials: Material_Table,
	width, height: i32,
) -> (
	ms: Material_Shaders,
) {
	prelude, prelude_err := os.read_entire_file_from_path(MATERIAL_SHADER_PRELUDE, context.allocator)
	if prelude_err != nil do return ms
	defer delete(prelude)

	epilogue, epilogue_err := os.read_entire_file_from_path(MATERIAL_SHADER_MAIN, context.allocator)
	if epilogue_err != nil do return ms
	defer delete(epilogue)

	list := make([dynamic]Material_Shader)

	for name, i in materials.names {
		if i > 255 do break

		path := material_shader_path(name, context.temp_allocator)
		if !os.exists(path) do continue

		body, body_err := os.read_entire_file_from_path(path, context.temp_allocator)
		if body_err != nil {
			fmt.eprintfln("%s did not read: %v", path, body_err)
			continue
		}

		source := material_shader_source(
			string(prelude),
			string(body),
			string(epilogue),
			context.temp_allocator,
		)
		text := strings.clone_to_cstring(source, context.temp_allocator)

		shader := rl.LoadShaderFromMemory(nil, text)
		if !rl.IsShaderValid(shader) {
			fmt.eprintfln("%s did not compile: %s is drawn flat", path, name)
			rl.UnloadShader(shader)
			continue
		}

		one := Material_Shader {
			shader = shader,
			cell   = Cell(i),
			name   = name,
		}
		for uniform_name, u in material_uniform_name {
			one.at[u] = rl.GetShaderLocation(shader, uniform_name)
		}
		append(&list, one)
	}

	if len(list) == 0 {
		delete(list)
		return ms
	}

	ms.list = list[:]
	ms.gbuf = make([]u8, int(width) * int(height) * 4)
	ms.run = make([]u8, int(width))
	ms.above = make([]Cell, int(width))

	blank := rl.Image {
		data    = raw_data(ms.gbuf),
		width   = width,
		height  = height,
		mipmaps = 1,
		format  = .UNCOMPRESSED_R8G8B8A8,
	}
	ms.texture = rl.LoadTextureFromImage(blank)
	rl.SetTextureFilter(ms.texture, .POINT)

	ms.on = true
	return ms
}

material_shaders_unload :: proc(ms: ^Material_Shaders) {
	if ms.on {
		rl.UnloadTexture(ms.texture)
		for one in ms.list do rl.UnloadShader(one.shader)
	}
	if ms.list != nil do delete(ms.list)
	if ms.gbuf != nil do delete(ms.gbuf)
	if ms.run != nil do delete(ms.run)
	if ms.above != nil do delete(ms.above)
	ms^ = {}
}

// One texel a cell: what the cell holds, the light on it, and how many
// cells of the same material stand over it. `seen` comes back saying
// which materials the view holds at all, so the draw skips the rest.
//
// The light goes in twice. The green channel holds the light the world
// shades by, which is the response curve applied, so a shader that mixes
// its own colour sinks into the dark exactly as the flat picture does.
// The alpha channel holds the raw light, which is what says how close a
// cell stands to a lamp.
material_gbuffer_fill :: proc(
	cells: []Cell,
	lux: []u8,
	w, h: i32,
	run: []u8,
	above: []Cell,
	out: []u8,
	seen: ^[256]bool,
) {
	for i in 0 ..< 256 do seen[i] = false
	for i in 0 ..< int(w) {
		run[i] = 0
		above[i] = 0
	}

	for y in 0 ..< int(h) {
		row := cells[y * int(w):][:w]
		line := lux[y * int(w):][:w]

		for x in 0 ..< int(w) {
			c := row[x]
			if c == above[x] {
				if run[x] < MATERIAL_DEEPEST do run[x] += 1
			} else {
				run[x] = 1
				above[x] = c
			}

			seen[u32(c) & 255] = true

			at := (y * int(w) + x) * 4
			out[at + 0] = u8(c)
			out[at + 1] = light_response[line[x]]
			out[at + 2] = run[x]
			out[at + 3] = line[x]
		}
	}
}

material_shaders_mark :: proc(ms: ^Material_Shaders, cells: []Cell, lux: []u8, w, h: i32) {
	if !ms.on do return
	material_gbuffer_fill(cells, lux, w, h, ms.run, ms.above, ms.gbuf, &ms.seen)
	rl.UpdateTextureRec(ms.texture, rl.Rectangle{0, 0, f32(w), f32(h)}, raw_data(ms.gbuf))
}

// Paint over the world, one material at a time. A material the view does
// not hold costs nothing: the pass is never drawn.
material_shaders_draw :: proc(
	ms: ^Material_Shaders,
	world: rl.Texture2D,
	src: rl.Rectangle,
	dst: rl.Rectangle,
	size: [2]f32,
	origin: [2]f32,
	step: f32,
	seconds: f32,
) {
	if !ms.on do return

	for &one in ms.list {
		if !ms.seen[u32(one.cell) & 255] do continue

		size := size
		origin := origin
		step := step
		seconds := seconds
		id := f32(one.cell)

		rl.BeginShaderMode(one.shader)
		rl.SetShaderValueTexture(one.shader, one.at[.Gbuf], ms.texture)
		rl.SetShaderValue(one.shader, one.at[.Size], &size, .VEC2)
		rl.SetShaderValue(one.shader, one.at[.Origin], &origin, .VEC2)
		rl.SetShaderValue(one.shader, one.at[.Step], &step, .FLOAT)
		rl.SetShaderValue(one.shader, one.at[.Seconds], &seconds, .FLOAT)
		rl.SetShaderValue(one.shader, one.at[.Id], &id, .FLOAT)
		rl.DrawTexturePro(world, src, dst, rl.Vector2{0, 0}, 0, rl.WHITE)
		rl.EndShaderMode()
	}
}

@(test)
test_the_gbuffer_names_the_material_and_the_light_of_every_cell :: proc(t: ^testing.T) {
	light_response_init()

	W :: 4
	H :: 3
	cells := [W * H]Cell{1, 2, 2, 3, 1, 1, 2, 3, 4, 1, 2, 3}
	lux := [W * H]u8{0, 10, 20, 30, 40, 50, 60, 70, 80, 90, 100, 110}

	out: [W * H * 4]u8
	run: [W]u8
	above: [W]Cell
	seen: [256]bool

	material_gbuffer_fill(cells[:], lux[:], W, H, run[:], above[:], out[:], &seen)

	for c, i in cells {
		testing.expectf(t, out[i * 4] == u8(c), "texel %d holds material %d and the buffer says %d", i, c, out[i * 4])
		testing.expectf(t, out[i * 4 + 3] == lux[i], "texel %d has light %d and the buffer says %d", i, lux[i], out[i * 4 + 3])
		testing.expectf(
			t,
			out[i * 4 + 1] == light_response[lux[i]],
			"texel %d shades by the response to %d and the buffer says %d",
			i,
			lux[i],
			out[i * 4 + 1],
		)
	}
}

@(test)
test_the_gbuffer_counts_the_run_of_one_material_over_a_cell :: proc(t: ^testing.T) {
	W :: 3
	H :: 5
	stone := Cell(7)
	air := Cell(0)

	cells := [W * H]Cell {
		stone, air, air,
		stone, air, stone,
		stone, stone, air,
		stone, stone, stone,
		air, stone, stone,
	}
	lux: [W * H]u8
	out: [W * H * 4]u8
	run: [W]u8
	above: [W]Cell
	seen: [256]bool

	material_gbuffer_fill(cells[:], lux[:], W, H, run[:], above[:], out[:], &seen)

	want := [W * H]u8 {
		1, 1, 1,
		2, 2, 1,
		3, 1, 1,
		4, 2, 1,
		1, 3, 2,
	}
	for w, i in want {
		testing.expectf(
			t,
			out[i * 4 + 2] == w,
			"texel %d stands %d cells into its own body and the buffer says %d",
			i,
			w,
			out[i * 4 + 2],
		)
	}
}

@(test)
test_the_gbuffer_names_only_the_materials_the_view_holds :: proc(t: ^testing.T) {
	W :: 2
	H :: 2
	cells := [W * H]Cell{3, 3, 9, 3}
	lux: [W * H]u8
	out: [W * H * 4]u8
	run: [W]u8
	above: [W]Cell
	seen: [256]bool

	material_gbuffer_fill(cells[:], lux[:], W, H, run[:], above[:], out[:], &seen)

	testing.expect(t, seen[3], "the view holds material 3")
	testing.expect(t, seen[9], "the view holds material 9")
	testing.expect(t, !seen[0], "the view holds no air, so no pass may draw it")
	testing.expect(t, !seen[255], "the view holds no material 255")
}

@(test)
test_the_run_never_reaches_past_the_deepest_a_texel_can_hold :: proc(t: ^testing.T) {
	W :: 1
	H :: MATERIAL_DEEPEST + 40
	cells: [W * H]Cell
	lux: [W * H]u8
	out: [W * H * 4]u8
	run: [W]u8
	above: [W]Cell
	seen: [256]bool

	for i in 0 ..< len(cells) do cells[i] = Cell(6)

	material_gbuffer_fill(cells[:], lux[:], W, H, run[:], above[:], out[:], &seen)

	testing.expect(t, out[2] == 1, "the top of a body of one material is its surface")
	testing.expectf(
		t,
		out[(H - 1) * 4 + 2] == MATERIAL_DEEPEST,
		"a body deeper than the texel can hold must stop at the deepest it can, and it reads %d",
		out[(H - 1) * 4 + 2],
	)
}

@(test)
test_every_material_shader_names_a_material_in_the_table :: proc(t: ^testing.T) {
	table, ok := load_materials(MATERIALS_PATH)
	if !testing.expect(t, ok, "the material table must load") do return
	defer destroy_material_table(table)

	pattern := strings.concatenate({MATERIAL_SHADER_DIR, "/*.fs"}, context.allocator)
	defer delete(pattern)

	files, err := filepath.glob(pattern, context.allocator)
	if !testing.expectf(t, err == nil, "%s must be readable, got %v", MATERIAL_SHADER_DIR, err) do return
	defer {
		for f in files do delete(f)
		delete(files)
	}

	testing.expect(t, len(files) > 0, "at least one material must bring a shader")

	for file in files {
		found := false
		for name in table.names {
			path := material_shader_path(name, context.temp_allocator)
			if path == file {
				found = true
				break
			}
		}
		testing.expectf(t, found, "%s names no material in %s", file, MATERIALS_PATH)
	}
	free_all(context.temp_allocator)
}

@(test)
test_the_prelude_declares_every_value_the_game_sets :: proc(t: ^testing.T) {
	source, err := os.read_entire_file_from_path(MATERIAL_SHADER_PRELUDE, context.allocator)
	if !testing.expectf(t, err == nil, "%s must ship with the game, got %v", MATERIAL_SHADER_PRELUDE, err) do return
	defer delete(source)

	text := string(source)
	testing.expect(t, strings.contains(text, "#version"), "the prelude must name the GLSL it is written in")

	for name, u in material_uniform_name {
		testing.expectf(
			t,
			material_declares(text, string(name)),
			"the game sets %v as %s, and %s declares no such uniform",
			u,
			name,
			MATERIAL_SHADER_PRELUDE,
		)
	}
}

@(test)
test_every_material_shader_holds_the_one_procedure_the_game_calls :: proc(t: ^testing.T) {
	pattern := strings.concatenate({MATERIAL_SHADER_DIR, "/*.fs"}, context.allocator)
	defer delete(pattern)

	files, err := filepath.glob(pattern, context.allocator)
	if !testing.expect(t, err == nil, "the shader folder must be readable") do return
	defer {
		for f in files do delete(f)
		delete(files)
	}

	for file in files {
		body, body_err := os.read_entire_file_from_path(file, context.temp_allocator)
		if !testing.expectf(t, body_err == nil, "%s must be readable", file) do continue

		text := string(body)
		testing.expectf(t, strings.contains(text, "vec3 shade(Surf s)"), "%s must hold `vec3 shade(Surf s)`, which is all the game calls", file)
		testing.expectf(t, !strings.contains(text, "void main("), "%s must hold no main: the epilogue brings it", file)
		testing.expectf(t, !strings.contains(text, "#version"), "%s must name no version: the prelude brings it", file)
	}
	free_all(context.temp_allocator)
}

@(private = "file")
material_declares :: proc(text: string, name: string) -> bool {
	rest := text
	for {
		at := strings.index(rest, "uniform ")
		if at < 0 do return false
		rest = rest[at + len("uniform "):]

		end := strings.index_byte(rest, ';')
		if end < 0 do return false

		line := rest[:end]
		space := strings.last_index_byte(line, ' ')
		if space >= 0 && line[space + 1:] == name do return true
	}
}
