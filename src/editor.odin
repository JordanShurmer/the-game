package game

import "core:fmt"
import rl "vendor:raylib"

/*
The in-game world editor.

You paint biomes onto the map, and the world behind the overlay
regenerates as you paint. There is no separate preview: the editor
calls the same generate path the game calls, so what you see is what
the player gets.

Save writes the map image. Save is blocked while any painted region
is cut off from the rest, because a world the player cannot walk
across is a mistake, not a style.
*/

EDITOR_PANEL_X :: 16
EDITOR_PANEL_W :: 290
MAP_AREA_X :: EDITOR_PANEL_X + EDITOR_PANEL_W + 24
MAP_AREA_Y :: 64
MAP_AREA_MAX :: 560

STATUS_SECONDS :: 4.0

/*
A line of feedback that fades. Both editors report saves and blocked
saves the same way, so they hold the same small struct rather than
each keeping three loose fields.
*/
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

// Draw the status line while it is still fresh.
status_draw :: proc(s: Status, x, y: i32) {
	if s.text == "" || rl.GetTime() >= s.until do return
	rl.DrawText(fmt.ctprintf("%s", s.text), x, y, 18, s.ok ? rl.GREEN : rl.RED)
}

Editor :: struct {
	open:            bool,
	brush:           Biome_Id,

	// One component label per map pixel. Stranded regions draw with a
	// warning outline, so the reason Save is blocked is on screen.
	labels:          []i32,
	component_count: int,

	status:          Status,
}

/*
The model half of the editor.

These procedures know about the world and the editor state, and
nothing about a mouse, a key, or a screen. The input handler below
calls them, and so does the MCP server. One path, so what a model
paints and what a hand paints go through the same code.
*/

editor_init :: proc(s: ^Sim) {
	s.editor.labels = make([]i32, len(s.world.biome_map.cells))
	s.editor.brush = 0
	editor_refresh(s)
}

editor_destroy :: proc(s: ^Sim) {
	delete(s.editor.labels)
	s.editor.labels = nil
}

// Recount the components. This runs after every change to the map.
// The map is small, so a full recount costs less than tracking edits.
editor_refresh :: proc(s: ^Sim) {
	s.editor.component_count = biome_map_label_components(s.world.biome_map, s.editor.labels)
}

editor_can_save :: proc(s: ^Sim) -> bool {
	return s.editor.component_count <= 1
}

editor_set_status :: proc(s: ^Sim, text: string, ok: bool) {
	status_set(&s.editor.status, text, ok)
}

// Is this map pixel inside the map?
editor_in_map :: proc(s: ^Sim, px, py: i32) -> bool {
	m := s.world.biome_map
	return px >= 0 && py >= 0 && px < m.width && py < m.height
}

/*
Paint one map pixel and recount the components.

The result says whether the map changed, so the caller knows whether
the world behind it has to be generated again.
*/
editor_paint_pixel :: proc(s: ^Sim, px, py: i32, id: Biome_Id) -> bool {
	if !editor_in_map(s, px, py) do return false
	if biome_map_at(s.world.biome_map, px, py) == id do return false

	biome_map_set(s.world.biome_map, px, py, id)
	editor_refresh(s)
	return true
}

// Clear one map pixel. An empty pixel generates as the off-map biome.
editor_erase_pixel :: proc(s: ^Sim, px, py: i32) -> bool {
	return editor_paint_pixel(s, px, py, BIOME_EMPTY)
}

/*
Write the map image.

Save is blocked while any painted region is cut off from the rest,
because a world the player cannot walk across is a mistake, not a
style. The result carries the reason, so a caller with no screen can
report it.
*/
editor_save_map :: proc(s: ^Sim) -> (message: string, ok: bool) {
	if !editor_can_save(s) {
		return fmt.tprintf(
			"save blocked: %d separate regions, join them first",
			s.editor.component_count,
		), false
	}

	path := s.world.biomes.map_image_path
	if save_biome_map_png(s.world.biome_map, s.world.biomes, path) {
		return fmt.tprintf("saved %s", path), true
	}
	return fmt.tprintf("cannot write %s", path), false
}

// The size of one map pixel on screen, and where the map starts.
@(private = "file")
editor_map_layout :: proc(app: ^App) -> (cell: i32, x0: i32, y0: i32) {
	m := app.world.biome_map
	longest := max(m.width, m.height)
	cell = max(MAP_AREA_MAX / max(longest, 1), 1)
	return cell, MAP_AREA_X, MAP_AREA_Y
}

// The map pixel under the mouse, if the mouse is over the map.
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

	// Pick a biome. The number keys follow the palette order.
	for key, i in ([]rl.KeyboardKey{.ONE, .TWO, .THREE, .FOUR, .FIVE, .SIX, .SEVEN, .EIGHT, .NINE}) {
		if i < len(app.world.biomes.biomes) && rl.IsKeyPressed(key) {
			e.brush = Biome_Id(i)
		}
	}

	px, py, over := editor_pixel_under_mouse(app)

	if over {
		// Paint on press and on drag, so a stroke covers a run of pixels.
		painted := false
		if rl.IsMouseButtonDown(.LEFT) {
			painted = editor_paint_pixel(&app.sim, px, py, e.brush)
		} else if rl.IsMouseButtonDown(.RIGHT) {
			painted = editor_erase_pixel(&app.sim, px, py)
		}

		// The world behind the overlay follows the stroke at once.
		if painted do app.dirty = true

		// Jump the camera to the region under the cursor, so you can
		// look at what you just painted.
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

	// Open the tile of the biome on the brush. This is the whole path
	// of Phase 2: pick a biome here, paint its tile, watch the world
	// behind both overlays follow the paint.
	if rl.IsKeyPressed(.T) {
		tile_editor_open(app, e.brush)
	}
}

// Centre the camera on the world region a map pixel covers.
editor_look_at_pixel :: proc(app: ^App, px, py: i32) {
	cpp := app.world.biomes.cells_per_pixel
	centre_x := (px - app.world.biomes.origin_pixel_x) * cpp + cpp / 2
	centre_y := (py - app.world.biomes.origin_pixel_y) * cpp + cpp / 2
	app.cam_x = centre_x - (WINDOW_W / 2) * app.step
	app.cam_y = centre_y - (WINDOW_H / 2) * app.step
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
	// The tile editor covers this one. Both overlays draw a palette in
	// the same place, so only the top one may draw.
	if !app.editor.open || app.tile_edit.open do return
	e := &app.editor

	// Dim the world, but keep it visible. The point of the editor is
	// to watch the world change while you paint.
	rl.DrawRectangle(0, 0, WINDOW_W, WINDOW_H, rl.Fade(rl.BLACK, 0.55))

	editor_draw_palette(app)
	editor_draw_map(app)

	// Status bar.
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

		// What the region becomes in the world: one flat material, or a
		// tile that T opens for painting.
		if b.tile == TILE_NONE {
			rl.DrawText(
				fmt.ctprintf("%s", app.world.materials.names[b.fill_0]),
				EDITOR_PANEL_X + 170,
				y + 2,
				14,
				rl.GRAY,
			)
		} else {
			rl.DrawText("tile  T", EDITOR_PANEL_X + 170, y + 2, 14, rl.SKYBLUE)
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
				// Empty pixels generate as the off-map biome. Show them
				// as a hole, not as that biome, so the map stays honest.
				rl.DrawRectangle(rx, ry, cell, cell, rl.Fade(rl.WHITE, 0.05))
			} else {
				rl.DrawRectangle(rx, ry, cell, cell, rl_from_argb(app.world.biomes.biomes[id].key_color))
			}
			rl.DrawRectangleLines(rx, ry, cell, cell, rl.Fade(rl.BLACK, 0.25))

			// Mark every component after the first, so the blocked save
			// points at the pixels that caused it.
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

	// The rectangle of world the camera shows, drawn on the map.
	editor_draw_camera_box(app, cell, x0, y0)

	// Highlight the pixel under the cursor.
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

	// Map pixel coordinates are fractional here, so the box shows the
	// camera exactly rather than snapping to a region.
	left := f32(app.cam_x) / f32(cpp) + f32(app.world.biomes.origin_pixel_x)
	top := f32(app.cam_y) / f32(cpp) + f32(app.world.biomes.origin_pixel_y)
	w := f32(WINDOW_W * app.step) / f32(cpp)
	h := f32(WINDOW_H * app.step) / f32(cpp)

	rl.DrawRectangleLinesEx(
		rl.Rectangle{f32(x0) + left * f32(cell), f32(y0) + top * f32(cell), w * f32(cell), h * f32(cell)},
		2,
		rl.Fade(rl.YELLOW, 0.9),
	)
}
