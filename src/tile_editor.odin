package game

import "core:fmt"
import testing "check"
import rl "vendor:raylib"

TILE_VIEW_CELL :: 1
TILE_VIEW_X :: 360
TILE_VIEW_Y :: 130
TILE_VIEW_SIZE :: TILE_SIZE * TILE_VIEW_CELL

TILE_CONTEXT :: WANG_SEAM * TILE_VIEW_CELL

SET_VIEW_X :: 940
SET_VIEW_Y :: 130
SET_SAMPLE :: 8
SET_PIXEL :: 1
SET_THUMB :: (TILE_SIZE / SET_SAMPLE) * SET_PIXEL
SET_COLUMNS :: 4
SET_GAP_X :: 12
SET_GAP_Y :: 22
SET_ROWS :: WANG_SIGNATURES / SET_COLUMNS

VARIANT_VIEW_Y :: SET_VIEW_Y + SET_ROWS * (SET_THUMB + SET_GAP_Y) + 28

TILE_PALETTE_TOP :: 96
TILE_PALETTE_ROW :: 26

Tile_Editor :: struct {
	open:       bool,
	biome:      Biome_Id,
	sig:        Wang_Signature,
	variant:    int,
	brush:      Cell,

	conflict:   Wang_Conflict,

	saved_step: i32,
	saved_zoom: i32,

	status:     Status,
}
tile_editor_begin :: proc(s: ^Sim, biome: Biome_Id) -> (message: string, ok: bool) {
	if int(biome) >= len(s.world.biomes.biomes) {
		return fmt.tprintf("there is no biome %d", biome), false
	}

	b := s.world.biomes.biomes[biome]
	if b.tile_base == TILE_NONE {
		return fmt.tprintf(
			"%s fills flat; give it 'generator = wang' and a 'tiles' prefix in %s to paint a set",
			s.world.biomes.names[biome],
			BIOMES_PATH,
		), false
	}

	e := &s.tile_edit
	e.open = true
	e.biome = biome
	e.sig = 0
	e.variant = 0
	e.brush = Cell(b.fill_0)
	tile_editor_refresh(s)

	return fmt.tprintf(
		"editing the %s set: %d tiles, %d per signature",
		s.world.biomes.names[biome],
		wang_set_size(b),
		int(b.variants),
	), true
}

tile_editor_biome :: proc(s: ^Sim) -> Biome {
	return s.world.biomes.biomes[s.tile_edit.biome]
}

tile_editor_tile :: proc(s: ^Sim) -> Tile_Id {
	return wang_tile_id(tile_editor_biome(s), s.tile_edit.sig, s.tile_edit.variant)
}
tile_editor_select :: proc(s: ^Sim, sig: int, variant: int) -> (message: string, ok: bool) {
	e := &s.tile_edit
	if !e.open do return "no set is open", false

	b := tile_editor_biome(s)
	if sig < 0 || sig >= WANG_SIGNATURES {
		return fmt.tprintf("a signature is 0 to %d", WANG_SIGNATURES - 1), false
	}
	if variant < 0 || variant >= int(b.variants) {
		return fmt.tprintf("%s draws %d variants of each signature", s.world.biomes.names[e.biome], b.variants), false
	}

	e.sig = Wang_Signature(sig)
	e.variant = variant
	return fmt.tprintf("tile %s", tile_editor_describe(s)), true
}

tile_editor_describe :: proc(s: ^Sim) -> string {
	e := &s.tile_edit
	return fmt.tprintf(
		"N%d E%d S%d W%d, variant %d",
		wang_north(e.sig),
		wang_east(e.sig),
		wang_south(e.sig),
		wang_west(e.sig),
		e.variant,
	)
}

tile_editor_step :: proc(s: ^Sim, delta: int) {
	e := &s.tile_edit
	if !e.open do return

	b := tile_editor_biome(s)
	index := (int(e.sig) * int(b.variants) + e.variant + delta) %% wang_set_size(b)
	e.sig = Wang_Signature(index / int(b.variants))
	e.variant = index %% int(b.variants)
}

tile_editor_paint_cell :: proc(s: ^Sim, x, y: i32, c: Cell) -> bool {
	e := &s.tile_edit
	if !e.open do return false
	if x < 0 || y < 0 || x >= TILE_SIZE || y >= TILE_SIZE do return false
	if int(c) >= len(s.world.materials.materials) do return false
	// A material with no physical interaction is not matter, so the terrain
	// cannot be made of one either. See docs/lighting.md.
	if material_is_phantom(s.world.materials.materials[c]) do return false

	tile := tile_editor_tile(s)
	if tile_at(s.world.tiles, tile, x, y) == c do return false

	if wang_band(x, y) == .Inside {
		tile_set_cell(s.world.tiles, tile, x, y, c)
		return true
	}

	wang_paint_cell(s.world.tiles, tile_editor_biome(s), e.sig, x, y, c)

	if e.conflict.found do tile_editor_refresh(s)
	return true
}

tile_editor_refresh :: proc(s: ^Sim) {
	e := &s.tile_edit
	e.conflict = wang_find_conflict(s.world.tiles, tile_editor_biome(s))
}

tile_editor_can_save :: proc(s: ^Sim) -> bool {
	return !s.tile_edit.conflict.found
}

tile_editor_normalize :: proc(s: ^Sim) -> (message: string, ok: bool) {
	e := &s.tile_edit
	if !e.open do return "no set is open", false

	changed := wang_normalize(s.world.tiles, tile_editor_biome(s))
	tile_editor_refresh(s)

	if changed == 0 do return "the seams already agree", true
	return fmt.tprintf("made %d seam cells agree", changed), true
}

tile_editor_save_tiles :: proc(s: ^Sim) -> (message: string, ok: bool) {
	e := &s.tile_edit
	if !e.open do return "no set is open", false

	if e.conflict.found {
		return fmt.tprintf(
			"save blocked: %s and %s disagree at cell %d,%d; press N to make the seams agree",
			biome_tile_path(s.world.biomes, e.biome, e.conflict.a),
			biome_tile_path(s.world.biomes, e.biome, e.conflict.b),
			e.conflict.x,
			e.conflict.y,
		), false
	}

	written, failed, save_ok := save_tile_set(s.world.tiles, s.world.biomes, e.biome, s.world.materials)
	if !save_ok {
		return fmt.tprintf("cannot write %s", failed), false
	}
	return fmt.tprintf("saved %d tiles of the %s set", written, s.world.biomes.names[e.biome]), true
}

tile_editor_neighbour :: proc(s: ^Sim, band: Wang_Band) -> (tile: Tile_Id, found: bool) {
	e := &s.tile_edit
	b := tile_editor_biome(s)
	if b.tile_base == TILE_NONE do return 0, false

	for other in 0 ..< WANG_SIGNATURES {
		sig := Wang_Signature(other)
		fits := false

		switch band {
		case .West:
			fits = wang_east(sig) == wang_west(e.sig)
		case .East:
			fits = wang_west(sig) == wang_east(e.sig)
		case .North:
			fits = wang_south(sig) == wang_north(e.sig)
		case .South:
			fits = wang_north(sig) == wang_south(e.sig)
		case .Corner, .Inside:
			return 0, false
		}

		if fits do return wang_tile_id(b, sig, 0), true
	}
	return 0, false
}

tile_editor_open :: proc(app: ^App, biome: Biome_Id) {
	message, ok := tile_editor_begin(&app.sim, biome)
	if !ok {
		editor_set_status(&app.sim, message, false)
		return
	}
	status_set(&app.tile_edit.status, message, true)

	app.tile_edit.saved_step = app.step
	app.tile_edit.saved_zoom = app.zoom

	if app.step != 1 || app.zoom != 1 {
		w0, h0 := app_view_cells(app)
		centre_x := app.cam_x + (w0 * app.step) / 2
		centre_y := app.cam_y + (h0 * app.step) / 2

		app.step = 1
		app.zoom = 1

		w1, h1 := app_view_cells(app)
		app.cam_x = centre_x - (w1 * app.step) / 2
		app.cam_y = centre_y - (h1 * app.step) / 2
		app.dirty = true
	}
}

tile_editor_close :: proc(app: ^App) {
	e := &app.tile_edit
	e.open = false

	if app.step != e.saved_step || app.zoom != e.saved_zoom {
		w0, h0 := app_view_cells(app)
		centre_x := app.cam_x + (w0 * app.step) / 2
		centre_y := app.cam_y + (h0 * app.step) / 2

		app.step = e.saved_step
		app.zoom = e.saved_zoom

		w1, h1 := app_view_cells(app)
		app.cam_x = centre_x - (w1 * app.step) / 2
		app.cam_y = centre_y - (h1 * app.step) / 2
		app.dirty = true
	}
}

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

	for m, i in app.world.materials.materials {
		row_y := i32(TILE_PALETTE_TOP) + i32(i) * TILE_PALETTE_ROW
		if y >= row_y && y < row_y + TILE_PALETTE_ROW {
			// A phantom is a light and not matter, so it is drawn in the
			// palette and cannot be picked out of it.
			if material_is_phantom(m) do return 0, false
			return Cell(i), true
		}
	}
	return 0, false
}

@(private = "file")
tile_editor_thumb_under_mouse :: proc() -> (sig: int, hit: bool) {
	mouse := rl.GetMousePosition()
	for i in 0 ..< WANG_SIGNATURES {
		x, y := tile_editor_thumb_position(i)
		if i32(mouse.x) >= x && i32(mouse.x) < x + SET_THUMB &&
		   i32(mouse.y) >= y && i32(mouse.y) < y + SET_THUMB {
			return i, true
		}
	}
	return 0, false
}

@(private = "file")
tile_editor_thumb_position :: proc(sig: int) -> (x: i32, y: i32) {
	column := i32(sig % SET_COLUMNS)
	row := i32(sig / SET_COLUMNS)
	return SET_VIEW_X + column * (SET_THUMB + SET_GAP_X), SET_VIEW_Y + row * (SET_THUMB + SET_GAP_Y)
}

@(private = "file")
tile_editor_variant_under_mouse :: proc(app: ^App) -> (variant: int, hit: bool) {
	b := tile_editor_biome(&app.sim)
	mouse := rl.GetMousePosition()

	for v in 0 ..< int(b.variants) {
		x := SET_VIEW_X + i32(v) * (SET_THUMB + SET_GAP_X)
		if i32(mouse.x) >= x && i32(mouse.x) < x + SET_THUMB &&
		   i32(mouse.y) >= VARIANT_VIEW_Y && i32(mouse.y) < VARIANT_VIEW_Y + SET_THUMB {
			return v, true
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

	for key, i in ([]rl.KeyboardKey{.ONE, .TWO, .THREE, .FOUR, .FIVE, .SIX, .SEVEN, .EIGHT, .NINE}) {
		if i < len(app.world.materials.materials) && rl.IsKeyPressed(key) {
			e.brush = Cell(i)
		}
	}

	if rl.IsKeyPressed(.RIGHT_BRACKET) do tile_editor_step(&app.sim, 1)
	if rl.IsKeyPressed(.LEFT_BRACKET) do tile_editor_step(&app.sim, -1)
	if rl.IsKeyPressed(.V) {
		b := tile_editor_biome(&app.sim)
		tile_editor_select(&app.sim, int(e.sig), (e.variant + 1) %% int(b.variants))
	}

	if x, y, over := tile_editor_cell_under_mouse(); over {
		painted := false
		if rl.IsMouseButtonDown(.LEFT) {
			painted = tile_editor_paint_cell(&app.sim, x, y, e.brush)
		} else if rl.IsMouseButtonDown(.RIGHT) {
			painted = tile_editor_paint_cell(&app.sim, x, y, MATERIAL_AIR)
		}

		if painted do app.dirty = true
	} else if rl.IsMouseButtonPressed(.LEFT) {
		if c, hit := tile_editor_palette_under_mouse(app); hit {
			e.brush = c
		} else if sig, thumb := tile_editor_thumb_under_mouse(); thumb {
			tile_editor_select(&app.sim, sig, e.variant)
		} else if v, variant := tile_editor_variant_under_mouse(app); variant {
			tile_editor_select(&app.sim, int(e.sig), v)
		}
	}

	if rl.IsKeyPressed(.S) do tile_editor_save(app)
	if rl.IsKeyPressed(.N) do tile_editor_repair(app)

	if rl.IsKeyPressed(.M) do tile_editor_look_at_biome(app)
}

tile_editor_save :: proc(app: ^App) {
	message, ok := tile_editor_save_tiles(&app.sim)
	status_set(&app.tile_edit.status, message, ok)
}

tile_editor_repair :: proc(app: ^App) {
	message, ok := tile_editor_normalize(&app.sim)
	status_set(&app.tile_edit.status, message, ok)
	app.dirty = true
}

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

@(private = "file")
tile_editor_edge_paint :: proc(color: u8) -> rl.Color {
	return color == 0 ? rl.Color{78, 104, 150, 255} : rl.Color{226, 156, 62, 255}
}

tile_editor_draw :: proc(app: ^App) {
	if !app.tile_edit.open do return
	e := &app.tile_edit

	rl.DrawRectangle(0, 0, WINDOW_W, WINDOW_H, rl.Fade(rl.BLACK, 0.55))

	tile_editor_draw_palette(app)
	tile_editor_draw_tile(app)
	tile_editor_draw_set(app)

	rl.DrawText(
		fmt.ctprintf("tile set - %s", app.world.biomes.names[e.biome]),
		EDITOR_PANEL_X,
		16,
		26,
		rl_from_argb(app.world.biomes.biomes[e.biome].key_color),
	)
	rl.DrawText(
		"LMB paint   RMB air   [ ] tile   V variant",
		EDITOR_PANEL_X,
		46,
		16,
		rl.GRAY,
	)
	rl.DrawText(
		"M look   N mend seams   S save   T close",
		EDITOR_PANEL_X,
		64,
		16,
		rl.GRAY,
	)

	if tile_editor_can_save(&app.sim) {
		rl.DrawText("the seams agree - save allowed", EDITOR_PANEL_X, WINDOW_H - 80, 20, rl.GREEN)
	} else {
		rl.DrawText(
			fmt.ctprintf(
				"tiles %d and %d disagree at %d,%d - press N",
				e.conflict.a,
				e.conflict.b,
				e.conflict.x,
				e.conflict.y,
			),
			EDITOR_PANEL_X,
			WINDOW_H - 80,
			20,
			rl.RED,
		)
	}

	rl.DrawText(
		fmt.ctprintf("%s", biome_tile_path(app.world.biomes, e.biome, tile_editor_tile(&app.sim))),
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

		tile_editor_draw_checker(EDITOR_PANEL_X, y, 18, 18)
		rl.DrawRectangle(EDITOR_PANEL_X, y, 18, 18, rl_from_argb(m.color))
		rl.DrawRectangleLines(EDITOR_PANEL_X, y, 18, 18, rl.Fade(rl.WHITE, 0.5))

		label := i < 9 ? fmt.ctprintf("%d %s", i + 1, app.world.materials.names[i]) \
		: fmt.ctprintf("  %s", app.world.materials.names[i])

		tint := selected ? rl.RAYWHITE : rl.LIGHTGRAY
		if material_is_phantom(m) do tint = rl.Fade(rl.LIGHTGRAY, 0.4)
		rl.DrawText(label, EDITOR_PANEL_X + 26, y, 18, tint)
	}
}

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
tile_editor_draw_cells :: proc(
	app: ^App,
	tile: Tile_Id,
	x0, y0: i32,
	cx, cy: i32,
	w, h: i32,
	scale: i32,
	sample: i32 = 1,
) {
	for y := i32(0); y < h; y += sample {
		for x := i32(0); x < w; x += sample {
			c := tile_at(app.world.tiles, tile, cx + x, cy + y)
			color := app.color_lut[c]
			if color.a == 0 do continue

			rl.DrawRectangle(
				x0 + (x / sample) * scale,
				y0 + (y / sample) * scale,
				scale,
				scale,
				color,
			)
		}
	}
}

@(private = "file")
tile_editor_draw_tile :: proc(app: ^App) {
	e := &app.tile_edit
	tile := tile_editor_tile(&app.sim)

	rl.DrawRectangle(
		TILE_VIEW_X - TILE_CONTEXT - 6,
		TILE_VIEW_Y - TILE_CONTEXT - 6,
		TILE_VIEW_SIZE + 2 * TILE_CONTEXT + 12,
		TILE_VIEW_SIZE + 2 * TILE_CONTEXT + 12,
		rl.Fade(rl.BLACK, 0.6),
	)
	tile_editor_draw_checker(TILE_VIEW_X, TILE_VIEW_Y, TILE_VIEW_SIZE, TILE_VIEW_SIZE)

	tile_editor_draw_cells(app, tile, TILE_VIEW_X, TILE_VIEW_Y, 0, 0, TILE_SIZE, TILE_SIZE, TILE_VIEW_CELL)

	tile_editor_draw_context(app)

	rl.DrawRectangleLines(
		TILE_VIEW_X + WANG_SEAM * TILE_VIEW_CELL,
		TILE_VIEW_Y + WANG_SEAM * TILE_VIEW_CELL,
		TILE_VIEW_SIZE - 2 * WANG_SEAM * TILE_VIEW_CELL,
		TILE_VIEW_SIZE - 2 * WANG_SEAM * TILE_VIEW_CELL,
		rl.Fade(rl.SKYBLUE, 0.5),
	)
	rl.DrawRectangleLines(TILE_VIEW_X, TILE_VIEW_Y, TILE_VIEW_SIZE, TILE_VIEW_SIZE, rl.Fade(rl.WHITE, 0.35))

	BAR :: 5
	rl.DrawRectangle(TILE_VIEW_X, TILE_VIEW_Y - TILE_CONTEXT - BAR, TILE_VIEW_SIZE, BAR, tile_editor_edge_paint(wang_north(e.sig)))
	rl.DrawRectangle(TILE_VIEW_X, TILE_VIEW_Y + TILE_VIEW_SIZE + TILE_CONTEXT, TILE_VIEW_SIZE, BAR, tile_editor_edge_paint(wang_south(e.sig)))
	rl.DrawRectangle(TILE_VIEW_X - TILE_CONTEXT - BAR, TILE_VIEW_Y, BAR, TILE_VIEW_SIZE, tile_editor_edge_paint(wang_west(e.sig)))
	rl.DrawRectangle(TILE_VIEW_X + TILE_VIEW_SIZE + TILE_CONTEXT, TILE_VIEW_Y, BAR, TILE_VIEW_SIZE, tile_editor_edge_paint(wang_east(e.sig)))

	rl.DrawText(
		fmt.ctprintf("tile %s", tile_editor_describe(&app.sim)),
		TILE_VIEW_X - TILE_CONTEXT,
		TILE_VIEW_Y - TILE_CONTEXT - 28,
		20,
		rl.RAYWHITE,
	)

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

		band := wang_band(x, y)
		reach := band == .Inside \
		? "this tile only" \
		: (band == .Corner ? "every tile of the set" : "every tile with that edge color")
		rl.DrawText(
			fmt.ctprintf(
				"cell %d, %d   %s   %v band, %s",
				x,
				y,
				app.world.materials.names[tile_at(app.world.tiles, tile, x, y)],
				band,
				reach,
			),
			TILE_VIEW_X - TILE_CONTEXT,
			TILE_VIEW_Y + TILE_VIEW_SIZE + TILE_CONTEXT + 12,
			16,
			rl.LIGHTGRAY,
		)
	}
}

@(private = "file")
tile_editor_draw_context :: proc(app: ^App) {
	if tile, found := tile_editor_neighbour(&app.sim, .West); found {
		tile_editor_draw_cells(
			app, tile,
			TILE_VIEW_X - TILE_CONTEXT, TILE_VIEW_Y,
			TILE_SIZE - WANG_SEAM, 0, WANG_SEAM, TILE_SIZE,
			TILE_VIEW_CELL,
		)
	}
	if tile, found := tile_editor_neighbour(&app.sim, .East); found {
		tile_editor_draw_cells(
			app, tile,
			TILE_VIEW_X + TILE_VIEW_SIZE, TILE_VIEW_Y,
			0, 0, WANG_SEAM, TILE_SIZE,
			TILE_VIEW_CELL,
		)
	}
	if tile, found := tile_editor_neighbour(&app.sim, .North); found {
		tile_editor_draw_cells(
			app, tile,
			TILE_VIEW_X, TILE_VIEW_Y - TILE_CONTEXT,
			0, TILE_SIZE - WANG_SEAM, TILE_SIZE, WANG_SEAM,
			TILE_VIEW_CELL,
		)
	}
	if tile, found := tile_editor_neighbour(&app.sim, .South); found {
		tile_editor_draw_cells(
			app, tile,
			TILE_VIEW_X, TILE_VIEW_Y + TILE_VIEW_SIZE,
			0, 0, TILE_SIZE, WANG_SEAM,
			TILE_VIEW_CELL,
		)
	}
}

@(private = "file")
tile_editor_draw_set :: proc(app: ^App) {
	e := &app.tile_edit
	b := tile_editor_biome(&app.sim)

	rl.DrawText("the set", SET_VIEW_X, SET_VIEW_Y - 28, 20, rl.RAYWHITE)

	for i in 0 ..< WANG_SIGNATURES {
		sig := Wang_Signature(i)
		x, y := tile_editor_thumb_position(i)
		tile := wang_tile_id(b, sig, min(e.variant, int(b.variants) - 1))

		tile_editor_draw_checker(x, y, SET_THUMB, SET_THUMB)
		tile_editor_draw_cells(app, tile, x, y, 0, 0, TILE_SIZE, TILE_SIZE, SET_PIXEL, SET_SAMPLE)

		EDGE :: 3
		rl.DrawRectangle(x, y - EDGE, SET_THUMB, EDGE, tile_editor_edge_paint(wang_north(sig)))
		rl.DrawRectangle(x, y + SET_THUMB, SET_THUMB, EDGE, tile_editor_edge_paint(wang_south(sig)))
		rl.DrawRectangle(x - EDGE, y, EDGE, SET_THUMB, tile_editor_edge_paint(wang_west(sig)))
		rl.DrawRectangle(x + SET_THUMB, y, EDGE, SET_THUMB, tile_editor_edge_paint(wang_east(sig)))

		if sig == e.sig {
			rl.DrawRectangleLinesEx(
				rl.Rectangle{f32(x - EDGE - 2), f32(y - EDGE - 2), f32(SET_THUMB + 2 * EDGE + 4), f32(SET_THUMB + 2 * EDGE + 4)},
				2,
				rl.RAYWHITE,
			)
		}

		rl.DrawText(
			fmt.ctprintf("%d%d%d%d", wang_north(sig), wang_east(sig), wang_south(sig), wang_west(sig)),
			x,
			y + SET_THUMB + EDGE + 2,
			14,
			sig == e.sig ? rl.RAYWHITE : rl.GRAY,
		)
	}

	rl.DrawText(
		fmt.ctprintf("variants of %d%d%d%d", wang_north(e.sig), wang_east(e.sig), wang_south(e.sig), wang_west(e.sig)),
		SET_VIEW_X,
		VARIANT_VIEW_Y - 22,
		16,
		rl.LIGHTGRAY,
	)

	for v in 0 ..< int(b.variants) {
		x := SET_VIEW_X + i32(v) * (SET_THUMB + SET_GAP_X)
		tile := wang_tile_id(b, e.sig, v)

		tile_editor_draw_checker(x, VARIANT_VIEW_Y, SET_THUMB, SET_THUMB)
		tile_editor_draw_cells(app, tile, x, VARIANT_VIEW_Y, 0, 0, TILE_SIZE, TILE_SIZE, SET_PIXEL, SET_SAMPLE)
		rl.DrawRectangleLines(
			x,
			VARIANT_VIEW_Y,
			SET_THUMB,
			SET_THUMB,
			v == e.variant ? rl.RAYWHITE : rl.Fade(rl.WHITE, 0.3),
		)
	}
}

@(test)
test_the_tile_editor_fits_the_window :: proc(t: ^testing.T) {
	testing.expectf(
		t,
		TILE_VIEW_X + TILE_VIEW_SIZE + TILE_CONTEXT <= WINDOW_W,
		"the tile view ends at %d, past the window's %d",
		TILE_VIEW_X + TILE_VIEW_SIZE + TILE_CONTEXT,
		WINDOW_W,
	)
	testing.expectf(
		t,
		TILE_VIEW_Y + TILE_VIEW_SIZE + TILE_CONTEXT <= WINDOW_H,
		"the tile view reaches %d down, past the window's %d",
		TILE_VIEW_Y + TILE_VIEW_SIZE + TILE_CONTEXT,
		WINDOW_H,
	)

	set_right := SET_VIEW_X + SET_COLUMNS * (SET_THUMB + SET_GAP_X)
	testing.expectf(
		t, set_right <= WINDOW_W,
		"the set of thumbnails ends at %d, past the window's %d", set_right, WINDOW_W,
	)
	testing.expectf(
		t, VARIANT_VIEW_Y + SET_THUMB <= WINDOW_H,
		"the variants reach %d down, past the window's %d", VARIANT_VIEW_Y + SET_THUMB, WINDOW_H,
	)
}
