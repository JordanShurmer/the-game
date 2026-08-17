package game

import "core:fmt"
import "core:os"
import rl "vendor:raylib"

/*
The game window.

The world view is a texture the size of the window. One texel is
`step` world cells. The app asks the generator for exactly the
rectangle it is about to show, and nothing more. There is no chunk
store yet, because nothing needs one.
*/

WINDOW_W :: 1280
WINDOW_H :: 720

/*
The window state.

Everything the game knows lives in the Sim. The App adds what only a
window needs: a camera, two buffers, and a texture. The MCP server
drives the same Sim with none of that, so the two cannot drift apart.
*/
App :: struct {
	using sim: Sim,

	// Camera. cam_x and cam_y are the world cell at the top-left texel.
	cam_x:     i32,
	cam_y:     i32,
	step:      i32, // world cells per screen pixel

	// The view buffers. cells holds material ids; pixels holds what
	// the texture shows. Both are the size of the window.
	cells:     []Cell,
	pixels:    []rl.Color,
	texture:   rl.Texture2D,

	// A material id maps to a color through this table. It is small
	// and read once per texel, so it stays hot.
	color_lut: [256]rl.Color,

	dirty:     bool,
}

BACKGROUND :: rl.Color{18, 20, 26, 255}

main :: proc() {
	app: App
	if !app_load_data(&app) {
		os.exit(1)
	}
	defer app_unload_data(&app)

	rl.SetTraceLogLevel(.WARNING)
	rl.InitWindow(WINDOW_W, WINDOW_H, "The Game - biome generation")
	defer rl.CloseWindow()
	rl.SetTargetFPS(60)

	app_init_view(&app)
	defer app_destroy_view(&app)

	for !rl.WindowShouldClose() {
		app_handle_input(&app)

		if app.dirty {
			app_regenerate(&app)
			app.dirty = false
		}

		rl.BeginDrawing()
		rl.ClearBackground(BACKGROUND)
		rl.DrawTexture(app.texture, 0, 0, rl.WHITE)
		draw_hud(&app)
		editor_draw(&app)
		tile_editor_draw(&app)
		rl.EndDrawing()

		free_all(context.temp_allocator)
	}
}

/*
Load the data files, then set up what only the window needs.

The load itself is sim_load, because the MCP server loads the same
world the same way.
*/
app_load_data :: proc(app: ^App) -> bool {
	if err := sim_load(&app.sim); err != .None do return false

	for m, i in app.world.materials.materials {
		app.color_lut[i] = rl_from_argb(m.color)
	}

	app.step = 8 // pulled back far enough to see whole regions
	app.cam_x = -(WINDOW_W / 2) * app.step
	app.cam_y = -(WINDOW_H / 2) * app.step
	app.dirty = true
	return true
}

app_unload_data :: proc(app: ^App) {
	sim_unload(&app.sim)
}

app_init_view :: proc(app: ^App) {
	app.cells = make([]Cell, WINDOW_W * WINDOW_H)
	app.pixels = make([]rl.Color, WINDOW_W * WINDOW_H)

	blank := rl.Image {
		data    = raw_data(app.pixels),
		width   = WINDOW_W,
		height  = WINDOW_H,
		mipmaps = 1,
		format  = .UNCOMPRESSED_R8G8B8A8,
	}
	app.texture = rl.LoadTextureFromImage(blank)
}

app_destroy_view :: proc(app: ^App) {
	rl.UnloadTexture(app.texture)
	delete(app.cells)
	delete(app.pixels)
}

/*
Generate what the window shows, then turn material ids into colors.

This is the one generate path. The editor calls it after every paint
stroke, and the game calls it after every camera move.
*/
app_regenerate :: proc(app: ^App) {
	view := World_View {
		x    = app.cam_x,
		y    = app.cam_y,
		w    = WINDOW_W,
		h    = WINDOW_H,
		step = app.step,
	}
	generate(app.world, view, app.cells)

	for c, i in app.cells {
		app.pixels[i] = app.color_lut[c]
	}
	rl.UpdateTexture(app.texture, raw_data(app.pixels))
}

app_handle_input :: proc(app: ^App) {
	// The tile editor sits on top of the world editor, so it reads the
	// keyboard first and nothing behind it moves while it is open.
	if app.tile_edit.open {
		tile_editor_handle_input(app)
		return
	}

	if rl.IsKeyPressed(.TAB) {
		app.editor.open = !app.editor.open
		if app.editor.open do editor_refresh(app)
	}

	if app.editor.open {
		editor_handle_input(app)
		return
	}

	// Pan. The speed follows the zoom, so the world moves at the same
	// rate on screen whatever the step is.
	pan := 8 * app.step
	moved := false
	if rl.IsKeyDown(.LEFT) || rl.IsKeyDown(.A) {app.cam_x -= pan;moved = true}
	if rl.IsKeyDown(.RIGHT) || rl.IsKeyDown(.D) {app.cam_x += pan;moved = true}
	if rl.IsKeyDown(.UP) || rl.IsKeyDown(.W) {app.cam_y -= pan;moved = true}
	if rl.IsKeyDown(.DOWN) || rl.IsKeyDown(.S) {app.cam_y += pan;moved = true}

	// Zoom about the middle of the window, so the view does not jump.
	zoom := 0
	if rl.IsKeyPressed(.EQUAL) || rl.IsKeyPressed(.KP_ADD) do zoom = -1
	if rl.IsKeyPressed(.MINUS) || rl.IsKeyPressed(.KP_SUBTRACT) do zoom = 1
	if wheel := rl.GetMouseWheelMove(); wheel > 0 {
		zoom = -1
	} else if wheel < 0 {
		zoom = 1
	}

	if zoom != 0 {
		old := app.step
		new_step := zoom < 0 ? old / 2 : old * 2
		new_step = clamp(new_step, 1, 256)
		if new_step != old {
			cx := app.cam_x + (WINDOW_W / 2) * old
			cy := app.cam_y + (WINDOW_H / 2) * old
			app.step = new_step
			app.cam_x = cx - (WINDOW_W / 2) * new_step
			app.cam_y = cy - (WINDOW_H / 2) * new_step
			moved = true
		}
	}

	if moved do app.dirty = true
}

draw_hud :: proc(app: ^App) {
	if app.editor.open || app.tile_edit.open do return

	cx := app.cam_x + (WINDOW_W / 2) * app.step
	cy := app.cam_y + (WINDOW_H / 2) * app.step
	id := world_biome_at(app.world, cx, cy)
	b := app.world.biomes.biomes[id]

	rl.DrawRectangle(0, 0, 460, 100, rl.Fade(rl.BLACK, 0.55))
	rl.DrawText(fmt.ctprintf("cell %d, %d   1px = %d cells", cx, cy, app.step), 12, 10, 18, rl.RAYWHITE)
	rl.DrawText(
		fmt.ctprintf("biome at centre: %s", app.world.biomes.names[id]),
		12,
		32,
		18,
		rl_from_argb(b.key_color),
	)

	// What the cell under the crosshair is made of. A tile biome shows
	// a different material every few cells, so the biome name alone no
	// longer says what you are looking at.
	cell := world_cell_at(app.world, cx, cy)
	source := b.tile == TILE_NONE ? "fill" : "tile"
	rl.DrawText(
		fmt.ctprintf("material: %s (%s)", app.world.materials.names[cell], source),
		12,
		54,
		18,
		rl_from_argb(app.world.materials.materials[cell].color | 0xFF000000),
	)
	rl.DrawText("WASD pan   wheel zoom   TAB world editor", 12, 76, 16, rl.GRAY)
}
