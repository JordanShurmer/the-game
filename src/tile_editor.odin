package game

import "core:fmt"
import rl "vendor:raylib"

/*
The in-game tile editor.

You pick a biome in the world editor and press T. The tile of that
biome opens, you paint materials into it, and every region of that
biome in the world changes under the overlay as you paint. There is no
preview: the world behind is the same generate path the game runs.

Save writes the tile PNG the biome names. There is no gate on it. A
tile cannot strand a region the way a biome map can, so there is
nothing here to block a save for.

This is the basic editor the phase asks for: one tile, painted by
hand, one cell at a time. No lattice, no edge colors, no template.
*/

// The tile fills this square on screen. TILE_SIZE divides it exactly,
// so a cell is a whole number of pixels and the grid never drifts.
TILE_VIEW_MAX :: 512
TILE_VIEW_CELL :: TILE_VIEW_MAX / TILE_SIZE
TILE_VIEW_X :: MAP_AREA_X
TILE_VIEW_Y :: MAP_AREA_Y

TILE_PALETTE_TOP :: 96
TILE_PALETTE_ROW :: 26

Tile_Editor :: struct {
	open:       bool,
	biome:      Biome_Id, // whose tile is open
	tile:       Tile_Id,
	brush:      Cell,     // the material being painted

	// The world editor works at whatever zoom you left it at, but tile
	// paint is one cell wide. The tile editor drops to 1 cell per pixel
	// so the paint is visible, and gives the old zoom back on close.
	saved_step: i32,

	status:     Status,
}

/*
Open the tile of a biome. A biome with no tile has nothing to paint,
and says so instead of opening an empty grid.
*/
tile_editor_open :: proc(app: ^App, biome: Biome_Id) {
	b := app.world.biomes.biomes[biome]
	if b.tile == TILE_NONE {
		editor_set_status(
			app,
			fmt.tprintf(
				"%s fills flat; give it 'generator = tile' in %s to paint one",
				app.world.biomes.names[biome],
				BIOMES_PATH,
			),
			false,
		)
		return
	}

	e := &app.tile_edit
	e.open = true
	e.biome = biome
	e.tile = b.tile
	e.brush = Cell(b.fill_0)
	e.saved_step = app.step

	// Show the world at native resolution, so one painted cell is one
	// pixel on screen instead of one sample in eight.
	if app.step != 1 {
		app.cam_x += (WINDOW_W / 2) * (app.step - 1)
		app.cam_y += (WINDOW_H / 2) * (app.step - 1)
		app.step = 1
		app.dirty = true
	}
}

tile_editor_close :: proc(app: ^App) {
	e := &app.tile_edit
	e.open = false

	if app.step != e.saved_step {
		app.cam_x -= (WINDOW_W / 2) * (e.saved_step - app.step)
		app.cam_y -= (WINDOW_H / 2) * (e.saved_step - app.step)
		app.step = e.saved_step
		app.dirty = true
	}
}

// The tile cell under the mouse, if the mouse is over the tile.
@(private = "file")
tile_editor_cell_under_mouse :: proc() -> (x: i32, y: i32, over: bool) {
	mouse := rl.GetMousePosition()
	fx := i32(mouse.x) - TILE_VIEW_X
	fy := i32(mouse.y) - TILE_VIEW_Y
	if fx < 0 || fy < 0 do return 0, 0, false

	x = fx / TILE_VIEW_CELL
	y = fy / TILE_VIEW_CELL
	if x >= TILE_SIZE || y >= TILE_SIZE do return 0, 0, false
	return x, y, true
}

@(private = "file")
tile_editor_palette_under_mouse :: proc(app: ^App) -> (c: Cell, hit: bool) {
	mouse := rl.GetMousePosition()
	x := i32(mouse.x)
	y := i32(mouse.y)
	if x < EDITOR_PANEL_X || x > EDITOR_PANEL_X + EDITOR_PANEL_W do return 0, false

	for _, i in app.world.materials.materials {
		row_y := i32(TILE_PALETTE_TOP) + i32(i) * TILE_PALETTE_ROW
		if y >= row_y && y < row_y + TILE_PALETTE_ROW {
			return Cell(i), true
		}
	}
	return 0, false
}

tile_editor_handle_input :: proc(app: ^App) {
	e := &app.tile_edit

	if rl.IsKeyPressed(.TAB) || rl.IsKeyPressed(.T) {
		tile_editor_close(app)
		return
	}

	// Pick a material. The number keys follow the palette order.
	for key, i in ([]rl.KeyboardKey{.ONE, .TWO, .THREE, .FOUR, .FIVE, .SIX, .SEVEN, .EIGHT, .NINE}) {
		if i < len(app.world.materials.materials) && rl.IsKeyPressed(key) {
			e.brush = Cell(i)
		}
	}

	if x, y, over := tile_editor_cell_under_mouse(); over {
		// Paint on press and on drag, so a stroke covers a run of cells.
		painted := false
		if rl.IsMouseButtonDown(.LEFT) {
			if tile_at(app.world.tiles, e.tile, x, y) != e.brush {
				tile_set_cell(app.world.tiles, e.tile, x, y, e.brush)
				painted = true
			}
		} else if rl.IsMouseButtonDown(.RIGHT) {
			// Erase is air, the way an empty pixel in the file is air.
			air := Cell(tile_editor_air(app))
			if tile_at(app.world.tiles, e.tile, x, y) != air {
				tile_set_cell(app.world.tiles, e.tile, x, y, air)
				painted = true
			}
		}

		// The world behind the overlay follows the stroke at once.
		if painted do app.dirty = true
	} else if rl.IsMouseButtonPressed(.LEFT) {
		if c, hit := tile_editor_palette_under_mouse(app); hit {
			e.brush = c
		}
	}

	if rl.IsKeyPressed(.S) do tile_editor_save(app)

	// Jump to a region the biome owns, so the paint is on screen.
	if rl.IsKeyPressed(.M) do tile_editor_look_at_biome(app)
}

// Air is the material a transparent pixel loads as. The editor looks
// it up by name once per erase, over a table of a dozen entries.
@(private = "file")
tile_editor_air :: proc(app: ^App) -> int {
	idx, found := find_material_index(app.world.materials, "Air")
	return found ? idx : 0
}

tile_editor_save :: proc(app: ^App) {
	e := &app.tile_edit
	path := app.world.biomes.tile_paths[e.tile]

	if save_tile_png(tile_cells(app.world.tiles, e.tile), app.world.materials, path) {
		status_set(&e.status, fmt.tprintf("saved %s", path), true)
	} else {
		status_set(&e.status, fmt.tprintf("cannot write %s", path), false)
	}
}

/*
Point the camera at a region this biome owns.

The tile repeats through every region of the biome, so the first
painted map pixel is as good as any other. A biome nobody has painted
yet has nowhere to look at, and the editor says so rather than moving
the camera somewhere that shows a different biome.
*/
tile_editor_look_at_biome :: proc(app: ^App) {
	e := &app.tile_edit
	m := app.world.biome_map

	for y in i32(0) ..< m.height {
		for x in i32(0) ..< m.width {
			if biome_map_at(m, x, y) != e.biome do continue
			editor_look_at_pixel(app, x, y)
			return
		}
	}

	status_set(
		&e.status,
		fmt.tprintf("%s is not painted on the map yet", app.world.biomes.names[e.biome]),
		false,
	)
}

tile_editor_draw :: proc(app: ^App) {
	if !app.tile_edit.open do return
	e := &app.tile_edit

	// Dim the world, but keep it visible. The point is to watch the
	// world change while you paint.
	rl.DrawRectangle(0, 0, WINDOW_W, WINDOW_H, rl.Fade(rl.BLACK, 0.55))

	tile_editor_draw_palette(app)
	tile_editor_draw_tile(app)

	rl.DrawText(
		fmt.ctprintf("tile editor - %s", app.world.biomes.names[e.biome]),
		EDITOR_PANEL_X,
		16,
		26,
		rl_from_argb(app.world.biomes.biomes[e.biome].key_color),
	)
	rl.DrawText(
		"LMB paint   RMB air   M look   S save   T close",
		EDITOR_PANEL_X,
		46,
		16,
		rl.GRAY,
	)
	rl.DrawText(
		fmt.ctprintf("%s", app.world.biomes.tile_paths[e.tile]),
		EDITOR_PANEL_X,
		WINDOW_H - 56,
		18,
		rl.LIGHTGRAY,
	)

	status_draw(e.status, EDITOR_PANEL_X, WINDOW_H - 30)
}

@(private = "file")
tile_editor_draw_palette :: proc(app: ^App) {
	count := i32(len(app.world.materials.materials))
	rl.DrawRectangle(
		EDITOR_PANEL_X - 8,
		TILE_PALETTE_TOP - 12,
		EDITOR_PANEL_W + 16,
		count * TILE_PALETTE_ROW + 16,
		rl.Fade(rl.BLACK, 0.6),
	)

	for m, i in app.world.materials.materials {
		y := i32(TILE_PALETTE_TOP) + i32(i) * TILE_PALETTE_ROW
		selected := Cell(i) == app.tile_edit.brush

		if selected {
			rl.DrawRectangle(
				EDITOR_PANEL_X - 4,
				y - 3,
				EDITOR_PANEL_W + 8,
				TILE_PALETTE_ROW,
				rl.Fade(rl.WHITE, 0.18),
			)
		}

		// Draw the swatch over a checker, so a transparent material
		// reads as empty rather than as black.
		tile_editor_draw_checker(EDITOR_PANEL_X, y, 18, 18)
		rl.DrawRectangle(EDITOR_PANEL_X, y, 18, 18, rl_from_argb(m.color))
		rl.DrawRectangleLines(EDITOR_PANEL_X, y, 18, 18, rl.Fade(rl.WHITE, 0.5))

		label := i < 9 ? fmt.ctprintf("%d %s", i + 1, app.world.materials.names[i]) \
		: fmt.ctprintf("  %s", app.world.materials.names[i])
		rl.DrawText(label, EDITOR_PANEL_X + 26, y, 18, selected ? rl.RAYWHITE : rl.LIGHTGRAY)
	}
}

// A grey checker, the way a pixel editor shows what is transparent.
@(private = "file")
tile_editor_draw_checker :: proc(x0, y0, w, h: i32) {
	SQUARE :: 8
	rl.DrawRectangle(x0, y0, w, h, rl.Color{52, 52, 58, 255})
	for y := i32(0); y < h; y += SQUARE {
		for x := i32(0); x < w; x += SQUARE {
			if ((x / SQUARE) + (y / SQUARE)) % 2 == 0 do continue
			rl.DrawRectangle(
				x0 + x,
				y0 + y,
				min(SQUARE, w - x),
				min(SQUARE, h - y),
				rl.Color{68, 68, 76, 255},
			)
		}
	}
}

@(private = "file")
tile_editor_draw_tile :: proc(app: ^App) {
	e := &app.tile_edit
	cells := tile_cells(app.world.tiles, e.tile)

	rl.DrawRectangle(
		TILE_VIEW_X - 6,
		TILE_VIEW_Y - 6,
		TILE_SIZE * TILE_VIEW_CELL + 12,
		TILE_SIZE * TILE_VIEW_CELL + 12,
		rl.Fade(rl.BLACK, 0.6),
	)
	tile_editor_draw_checker(
		TILE_VIEW_X,
		TILE_VIEW_Y,
		TILE_SIZE * TILE_VIEW_CELL,
		TILE_SIZE * TILE_VIEW_CELL,
	)

	for y in i32(0) ..< TILE_SIZE {
		for x in i32(0) ..< TILE_SIZE {
			c := cells[int(y) * TILE_SIZE + int(x)]
			color := rl_from_argb(app.world.materials.materials[c].color)
			if color.a == 0 do continue // air shows the checker behind

			rl.DrawRectangle(
				TILE_VIEW_X + x * TILE_VIEW_CELL,
				TILE_VIEW_Y + y * TILE_VIEW_CELL,
				TILE_VIEW_CELL,
				TILE_VIEW_CELL,
				color,
			)
		}
	}

	rl.DrawRectangleLines(
		TILE_VIEW_X,
		TILE_VIEW_Y,
		TILE_SIZE * TILE_VIEW_CELL,
		TILE_SIZE * TILE_VIEW_CELL,
		rl.Fade(rl.WHITE, 0.35),
	)

	// The cell under the cursor, and what it holds.
	if x, y, over := tile_editor_cell_under_mouse(); over {
		rl.DrawRectangleLinesEx(
			rl.Rectangle {
				f32(TILE_VIEW_X + x * TILE_VIEW_CELL),
				f32(TILE_VIEW_Y + y * TILE_VIEW_CELL),
				f32(TILE_VIEW_CELL),
				f32(TILE_VIEW_CELL),
			},
			2,
			rl.RAYWHITE,
		)
		rl.DrawText(
			fmt.ctprintf(
				"cell %d, %d   %s",
				x,
				y,
				app.world.materials.names[tile_at(app.world.tiles, e.tile, x, y)],
			),
			TILE_VIEW_X,
			TILE_VIEW_Y + TILE_SIZE * TILE_VIEW_CELL + 12,
			16,
			rl.LIGHTGRAY,
		)
	}
}
