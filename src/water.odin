package game

import "core:strings"
import testing "check"
import rl "vendor:raylib"

WATER_SHADER_PATH :: "data/shaders/water.fs"
WATER_MATERIAL :: "Water"

WATER_DEEPEST :: 255

Water_Uniform :: enum u8 {
	Mask,
	Size,
	Origin,
	Step,
	Seconds,
}

water_uniform_name := [Water_Uniform]cstring {
	.Mask    = "mask",
	.Size    = "size",
	.Origin  = "origin",
	.Step    = "step_cells",
	.Seconds = "seconds",
}

Water :: struct {
	shader:  rl.Shader,
	at:      [Water_Uniform]i32,
	depth:   []u8,
	texture: rl.Texture2D,
	cell:    Cell,
	box:     Sandbox_Rect, // the cells the water actually covers
	on:      bool,
}

water_depth_fill :: proc(cells: []Cell, w, h: i32, water: Cell, run: []u8, out: []u8) -> (box: Sandbox_Rect) {
	box = SANDBOX_RECT_EMPTY
	for i in 0 ..< int(w) do run[i] = 0

	for y in 0 ..< int(h) {
		row := cells[y * int(w):][:w]
		line := out[y * int(w):][:w]

		for x in 0 ..< int(w) {
			if row[x] != water {
				run[x] = 0
				line[x] = 0
				continue
			}
			if run[x] < WATER_DEEPEST do run[x] += 1
			line[x] = run[x]

			box.min_x = min(box.min_x, i32(x))
			box.min_y = min(box.min_y, i32(y))
			box.max_x = max(box.max_x, i32(x))
			box.max_y = max(box.max_y, i32(y))
		}
	}
	return box
}

water_load :: proc(materials: Material_Table, width, height: i32) -> (water: Water) {
	cell, found := find_material_index(materials, WATER_MATERIAL)
	if !found do return water
	water.cell = Cell(cell)

	if !file_exists(WATER_SHADER_PATH) do return water

	path := strings.clone_to_cstring(WATER_SHADER_PATH, context.temp_allocator)
	water.shader = rl.LoadShader(nil, path)
	if !rl.IsShaderValid(water.shader) {
		rl.UnloadShader(water.shader)
		water.shader = {}
		return water
	}

	for name, u in water_uniform_name {
		water.at[u] = rl.GetShaderLocation(water.shader, name)
	}

	water.depth = make([]u8, int(width) * int(height))

	blank := rl.Image {
		data    = raw_data(water.depth),
		width   = width,
		height  = height,
		mipmaps = 1,
		format  = .UNCOMPRESSED_GRAYSCALE,
	}
	water.texture = rl.LoadTextureFromImage(blank)
	rl.SetTextureFilter(water.texture, .POINT)

	water.on = true
	return water
}

water_unload :: proc(water: ^Water) {
	if water.depth != nil do delete(water.depth)
	if water.on {
		rl.UnloadTexture(water.texture)
		rl.UnloadShader(water.shader)
	}
	water^ = {}
}

water_mark :: proc(water: ^Water, cells: []Cell, w, h: i32, run: []u8) {
	if !water.on do return
	water.box = water_depth_fill(cells, w, h, water.cell, run, water.depth)
	if water.box.min_x > water.box.max_x do return // no water: nothing to upload or draw
	rl.UpdateTextureRec(water.texture, rl.Rectangle{0, 0, f32(w), f32(h)}, raw_data(water.depth))
}

water_begin :: proc(water: ^Water, size: [2]f32, origin: [2]f32, step: f32, seconds: f32) {
	if !water.on do return

	size := size
	origin := origin
	step := step
	seconds := seconds

	rl.BeginShaderMode(water.shader)
	rl.SetShaderValueTexture(water.shader, water.at[.Mask], water.texture)
	rl.SetShaderValue(water.shader, water.at[.Size], &size, .VEC2)
	rl.SetShaderValue(water.shader, water.at[.Origin], &origin, .VEC2)
	rl.SetShaderValue(water.shader, water.at[.Step], &step, .FLOAT)
	rl.SetShaderValue(water.shader, water.at[.Seconds], &seconds, .FLOAT)
}

water_end :: proc(water: ^Water) {
	if !water.on do return
	rl.EndShaderMode()
}

@(test)
test_the_depth_map_marks_water_and_nothing_else :: proc(t: ^testing.T) {
	W :: 6
	H :: 4
	water := Cell(3)
	rock := Cell(9)

	cells := [W * H]Cell {
		rock, water, water, rock, rock, rock,
		rock, water, water, water, rock, rock,
		rock, water, rock, water, rock, rock,
		rock, water, rock, water, rock, water,
	}
	out: [W * H]u8
	run: [W]u8

	water_depth_fill(cells[:], W, H, water, run[:], out[:])

	for c, i in cells {
		wet := out[i] != 0
		testing.expectf(
			t,
			wet == (c == water),
			"texel %d holds material %d and the depth map says wet=%v",
			i,
			c,
			wet,
		)
	}
}

@(test)
test_the_depth_map_counts_the_water_over_a_cell :: proc(t: ^testing.T) {
	W :: 3
	H :: 5
	water := Cell(1)
	rock := Cell(2)

	cells := [W * H]Cell {
		water, rock, rock,
		water, rock, water,
		water, water, rock,
		water, water, water,
		rock, water, water,
	}
	out: [W * H]u8
	run: [W]u8

	water_depth_fill(cells[:], W, H, water, run[:], out[:])

	want := [W * H]u8 {
		1, 0, 0,
		2, 0, 1,
		3, 1, 0,
		4, 2, 1,
		0, 3, 2,
	}

	for w, i in want {
		testing.expectf(
			t,
			out[i] == w,
			"texel %d is %d cells under the surface and the map says %d",
			i,
			w - 1,
			int(out[i]) - 1,
		)
	}
}

@(test)
test_the_depth_map_never_runs_past_the_deepest_it_can_hold :: proc(t: ^testing.T) {
	W :: 1
	H :: WATER_DEEPEST + 40
	water := Cell(1)

	cells: [W * H]Cell
	out: [W * H]u8
	run: [W]u8
	for i in 0 ..< len(cells) do cells[i] = water

	water_depth_fill(cells[:], W, H, water, run[:], out[:])

	testing.expect(t, out[0] == 1, "the top of a column of water is the surface")
	testing.expectf(
		t,
		out[len(out) - 1] == WATER_DEEPEST,
		"a column deeper than the map can hold must stop at the deepest it can, and it reads %d",
		out[len(out) - 1],
	)
}

@(test)
test_the_shader_declares_every_value_the_game_sets :: proc(t: ^testing.T) {
	source, ok := file_read(WATER_SHADER_PATH, context.allocator)
	if !testing.expectf(t, ok, "%s must ship with the game", WATER_SHADER_PATH) do return
	defer delete(source)

	text := string(source)
	testing.expect(t, strings.contains(text, "#version"), "the shader must name the GLSL it is written in")

	for name, u in water_uniform_name {
		testing.expectf(
			t,
			water_declares(text, string(name)),
			"the game sets %v as %s, and %s declares no such uniform",
			u,
			name,
			WATER_SHADER_PATH,
		)
	}
}

@(private = "file")
water_declares :: proc(text: string, name: string) -> bool {
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
