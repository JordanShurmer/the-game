package game

import "core:fmt"
import rl "vendor:raylib"

EDITOR_PANEL_X :: 16
EDITOR_PANEL_W :: 290
MAP_AREA_X :: EDITOR_PANEL_X + EDITOR_PANEL_W + 24
MAP_AREA_Y :: 64
MAP_AREA_MAX :: 560

STATUS_SECONDS :: 4.0
Status :: struct {
	text:  string,
	ok:    bool,
	until: f64,
}

status_set :: proc(s: ^Status, text: string, ok: bool) {
	s.text = text
	s.ok = ok
	s.until = rl.GetTime() + STATUS_SECONDS
}

status_draw :: proc(s: Status, x, y: i32) {
	if s.text == "" || rl.GetTime() >= s.until do return
	rl.DrawText(fmt.ctprintf("%s", s.text), x, y, 18, s.ok ? rl.GREEN : rl.RED)
}

Editor :: struct {
	open:            bool,
	brush:           Biome_Id,

	labels:          []i32,
	component_count: int,

	status:          Status,
}

editor_init :: proc(s: ^Sim) {
	s.editor.labels = make([]i32, len(s.world.biome_map.cells))
	s.editor.brush = 0
	editor_refresh(s)
}

editor_destroy :: proc(s: ^Sim) {
	delete(s.editor.labels)
	s.editor.labels = nil
}

editor_refresh :: proc(s: ^Sim) {
	s.editor.component_count = biome_map_label_components(s.world.biome_map, s.editor.labels)
}

editor_can_save :: proc(s: ^Sim) -> bool {
	return s.editor.component_count <= 1
}

editor_set_status :: proc(s: ^Sim, text: string, ok: bool) {
	status_set(&s.editor.status, text, ok)
}

editor_in_map :: proc(s: ^Sim, px, py: i32) -> bool {
	m := s.world.biome_map
	return px >= 0 && py >= 0 && px < m.width && py < m.height
}
editor_paint_pixel :: proc(s: ^Sim, px, py: i32, id: Biome_Id) -> bool {
	if !editor_in_map(s, px, py) do return false
	if biome_map_at(s.world.biome_map, px, py) == id do return false

	biome_map_set(s.world.biome_map, px, py, id)
	editor_refresh(s)
	return true
}

editor_erase_pixel :: proc(s: ^Sim, px, py: i32) -> bool {
	return editor_paint_pixel(s, px, py, BIOME_EMPTY)
}
editor_save_map :: proc(s: ^Sim) -> (message: string, ok: bool) {
	if !editor_can_save(s) {
		return fmt.tprintf(
			"save blocked: %d separate regions, join them first",
			s.editor.component_count,
		), false
	}

	// The picture this world is painted on, which is not always the
	// ordinary one: a map edited in the Laboratory saves the Laboratory.
	path := world_layout(s.world.biomes, s.world.seed).map_image_path
	if save_biome_map_png(s.world.biome_map, s.world.biomes, path) {
		return fmt.tprintf("saved %s", path), true
	}
	return fmt.tprintf("cannot write %s", path), false
}

@(private = "file")
editor_map_layout :: proc(app: ^App) -> (cell: i32, x0: i32, y0: i32) {
	m := app.world.biome_map
	longest := max(m.width, m.height)
	cell = max(MAP_AREA_MAX / max(longest, 1), 1)
	return cell, MAP_AREA_X, MAP_AREA_Y
}

@(private = "file")
editor_pixel_under_mouse :: proc(app: ^App) -> (px: i32, py: i32, over: bool) {
	cell, x0, y0 := editor_map_layout(app)
	m := app.world.biome_map

	mouse := rl.GetMousePosition()
	fx := i32(mouse.x) - x0
	fy := i32(mouse.y) - y0
	if fx < 0 || fy < 0 do return 0, 0, false

	px = fx / cell
	py = fy / cell
	if px >= m.width || py >= m.height do return 0, 0, false
	return px, py, true
}

editor_handle_input :: proc(app: ^App) {
	e := &app.editor

	for key, i in ([]rl.KeyboardKey{.ONE, .TWO, .THREE, .FOUR, .FIVE, .SIX, .SEVEN, .EIGHT, .NINE}) {
		if i < len(app.world.biomes.biomes) && rl.IsKeyPressed(key) {
			e.brush = Biome_Id(i)
		}
	}

	px, py, over := editor_pixel_under_mouse(app)

	if over {
		painted := false
		if rl.IsMouseButtonDown(.LEFT) {
			painted = editor_paint_pixel(&app.sim, px, py, e.brush)
		} else if rl.IsMouseButtonDown(.RIGHT) {
			painted = editor_erase_pixel(&app.sim, px, py)
		}

		if painted do app.dirty = true

		if rl.IsMouseButtonPressed(.MIDDLE) || rl.IsKeyPressed(.M) {
			editor_look_at_pixel(app, px, py)
		}
	} else if rl.IsMouseButtonPressed(.LEFT) {
		if id, hit := editor_palette_under_mouse(app); hit {
			e.brush = id
		}
	}

	if rl.IsKeyPressed(.S) {
		editor_save(app)
	}

	if rl.IsKeyPressed(.T) {
		tile_editor_open(app, e.brush)
	}
}

editor_look_at_pixel :: proc(app: ^App, px, py: i32) {
	cpp := app.world.biomes.cells_per_pixel
	centre_x := (px - app.world.biomes.origin_pixel_x) * cpp + cpp / 2
	centre_y := (py - app.world.biomes.origin_pixel_y) * cpp + cpp / 2

	w, h := app_view_cells(app)
	app.cam_x = centre_x - (w / 2) * app.step
	app.cam_y = centre_y - (h / 2) * app.step
	app.dirty = true
}

editor_save :: proc(app: ^App) {
	message, ok := editor_save_map(&app.sim)
	editor_set_status(&app.sim, message, ok)
}

@(private = "file")
editor_palette_row_height :: 26

@(private = "file")
editor_palette_under_mouse :: proc(app: ^App) -> (id: Biome_Id, hit: bool) {
	mouse := rl.GetMousePosition()
	x := i32(mouse.x)
	y := i32(mouse.y)
	if x < EDITOR_PANEL_X || x > EDITOR_PANEL_X + EDITOR_PANEL_W do return 0, false

	top := i32(96)
	for _, i in app.world.biomes.biomes {
		row_y := top + i32(i) * editor_palette_row_height
		if y >= row_y && y < row_y + editor_palette_row_height {
			return Biome_Id(i), true
		}
	}
	return 0, false
}

editor_draw :: proc(app: ^App) {
	if !app.editor.open || app.tile_edit.open do return
	e := &app.editor

	rl.DrawRectangle(0, 0, WINDOW_W, WINDOW_H, rl.Fade(rl.BLACK, 0.55))

	editor_draw_palette(app)
	editor_draw_map(app)

	rl.DrawText("world editor", EDITOR_PANEL_X, 16, 26, rl.RAYWHITE)
	rl.DrawText(
		"LMB paint   RMB erase   M look   T tile   S save   TAB close",
		EDITOR_PANEL_X,
		46,
		16,
		rl.GRAY,
	)

	connected := editor_can_save(&app.sim)
	gate := connected \
	? fmt.ctprintf("connected - save allowed") \
	: fmt.ctprintf("%d separate regions - save blocked", e.component_count)
	rl.DrawText(gate, EDITOR_PANEL_X, WINDOW_H - 56, 20, connected ? rl.GREEN : rl.RED)

	status_draw(e.status, EDITOR_PANEL_X, WINDOW_H - 30)
}

@(private = "file")
editor_draw_palette :: proc(app: ^App) {
	rl.DrawRectangle(EDITOR_PANEL_X - 8, 84, EDITOR_PANEL_W + 16, i32(len(app.world.biomes.biomes)) * editor_palette_row_height + 16, rl.Fade(rl.BLACK, 0.6))

	top := i32(96)
	for b, i in app.world.biomes.biomes {
		y := top + i32(i) * editor_palette_row_height
		selected := Biome_Id(i) == app.editor.brush

		if selected {
			rl.DrawRectangle(EDITOR_PANEL_X - 4, y - 3, EDITOR_PANEL_W + 8, editor_palette_row_height, rl.Fade(rl.WHITE, 0.18))
		}

		rl.DrawRectangle(EDITOR_PANEL_X, y, 18, 18, rl_from_argb(b.key_color))
		rl.DrawRectangleLines(EDITOR_PANEL_X, y, 18, 18, rl.Fade(rl.WHITE, 0.5))

		rl.DrawText(
			fmt.ctprintf("%d %s", i + 1, app.world.biomes.names[i]),
			EDITOR_PANEL_X + 26,
			y,
			18,
			selected ? rl.RAYWHITE : rl.LIGHTGRAY,
		)

		if b.tile_base == TILE_NONE {
			rl.DrawText(
				fmt.ctprintf("%s", app.world.materials.names[b.fill_0]),
				EDITOR_PANEL_X + 170,
				y + 2,
				14,
				rl.GRAY,
			)
		} else {
			rl.DrawText(
				fmt.ctprintf("%d tiles  T", wang_set_size(b)),
				EDITOR_PANEL_X + 170,
				y + 2,
				14,
				rl.SKYBLUE,
			)
		}
	}
}

@(private = "file")
editor_draw_map :: proc(app: ^App) {
	e := &app.editor
	m := app.world.biome_map
	cell, x0, y0 := editor_map_layout(app)

	rl.DrawRectangle(x0 - 6, y0 - 6, m.width * cell + 12, m.height * cell + 12, rl.Fade(rl.BLACK, 0.6))

	for y in i32(0) ..< m.height {
		for x in i32(0) ..< m.width {
			id := biome_map_at(m, x, y)
			rx := x0 + x * cell
			ry := y0 + y * cell

			if id == BIOME_EMPTY {
				rl.DrawRectangle(rx, ry, cell, cell, rl.Fade(rl.WHITE, 0.05))
			} else {
				rl.DrawRectangle(rx, ry, cell, cell, rl_from_argb(app.world.biomes.biomes[id].key_color))
			}
			rl.DrawRectangleLines(rx, ry, cell, cell, rl.Fade(rl.BLACK, 0.25))

			if e.component_count > 1 {
				label := e.labels[int(y) * int(m.width) + int(x)]
				if label > 0 {
					rl.DrawRectangleLinesEx(
						rl.Rectangle{f32(rx), f32(ry), f32(cell), f32(cell)},
						2,
						rl.RED,
					)
				}
			}
		}
	}

	editor_draw_camera_box(app, cell, x0, y0)

	if px, py, over := editor_pixel_under_mouse(app); over {
		rl.DrawRectangleLinesEx(
			rl.Rectangle{f32(x0 + px * cell), f32(y0 + py * cell), f32(cell), f32(cell)},
			2,
			rl.RAYWHITE,
		)
		rl.DrawText(
			fmt.ctprintf("pixel %d, %d", px, py),
			x0,
			y0 + m.height * cell + 12,
			16,
			rl.LIGHTGRAY,
		)
	}
}

@(private = "file")
editor_draw_camera_box :: proc(app: ^App, cell, x0, y0: i32) {
	cpp := app.world.biomes.cells_per_pixel

	left := f32(app.cam_x) / f32(cpp) + f32(app.world.biomes.origin_pixel_x)
	top := f32(app.cam_y) / f32(cpp) + f32(app.world.biomes.origin_pixel_y)

	view_w, view_h := app_view_cells(app)
	w := f32(view_w * app.step) / f32(cpp)
	h := f32(view_h * app.step) / f32(cpp)

	rl.DrawRectangleLinesEx(
		rl.Rectangle{f32(x0) + left * f32(cell), f32(y0) + top * f32(cell), w * f32(cell), h * f32(cell)},
		2,
		rl.Fade(rl.YELLOW, 0.9),
	)
}
