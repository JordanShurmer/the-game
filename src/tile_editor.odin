package game

import "core:fmt"
import rl "vendor:raylib"

/*
The in-game tile editor.

You pick a biome in the world editor and press T. The whole tile set
of that biome opens, you paint materials into one tile of it, and
every region of that biome in the world changes under the overlay as
you paint. There is no preview: the world behind is the same generate
path the game runs.

A set is not a pile of pictures. Every tile carries four edge colors,
and the world only ever puts two tiles side by side when they agree
about the edge between them. So the cells along a side do not belong
to the tile. They belong to the edge color, and every tile that
carries that color holds the same cells there.

The editor keeps that true instead of asking the author to. A stroke
in the middle of a tile touches that tile. A stroke in a border band
reaches every tile with the same color on that side, because that is
the same seam seen from another tile. The bands are drawn, the edge
colors are drawn, and the neighbour that would sit beyond each side is
drawn beside it, so what you are painting is always a joined picture
rather than four loose edges.

Save writes every file of the set. It is blocked while the set
disagrees with itself, which only happens to files painted somewhere
else. N makes them agree again.
*/

// The tile fills this square on screen. TILE_SIZE divides it exactly,
// so a cell is a whole number of pixels and the grid never drifts.
TILE_VIEW_CELL :: 8
TILE_VIEW_X :: 360
TILE_VIEW_Y :: 130
TILE_VIEW_SIZE :: TILE_SIZE * TILE_VIEW_CELL

// The strip of the neighbour beyond each side, at the same scale.
TILE_CONTEXT :: WANG_SEAM * TILE_VIEW_CELL

// The set, as thumbnails. A thumbnail samples every other cell, the
// way the world view samples when the camera pulls back.
SET_VIEW_X :: 940
SET_VIEW_Y :: 130
SET_SAMPLE :: 2
SET_THUMB :: (TILE_SIZE / SET_SAMPLE) * SET_SAMPLE // 64 pixels
SET_COLUMNS :: 4
SET_GAP_X :: 12
SET_GAP_Y :: 22
SET_ROWS :: WANG_SIGNATURES / SET_COLUMNS

VARIANT_VIEW_Y :: SET_VIEW_Y + SET_ROWS * (SET_THUMB + SET_GAP_Y) + 28

TILE_PALETTE_TOP :: 96
TILE_PALETTE_ROW :: 26

Tile_Editor :: struct {
	open:       bool,
	biome:      Biome_Id,      // whose set is open
	sig:        Wang_Signature, // which tile of it is being painted
	variant:    int,
	brush:      Cell,          // the material being painted

	// Where the set disagrees with itself, if it does. It gates the
	// save, the same way a cut map gates the biome map save.
	conflict:   Wang_Conflict,

	// The world editor works at whatever step and zoom you left it at,
	// but tile paint is one cell wide. The tile editor drops both to 1
	// so the paint is visible at native resolution, and gives the old
	// values back on close.
	saved_step: i32,
	saved_zoom: i32,

	status:     Status,
}

/*
The model half of the tile editor.

Like the world editor, these know the world and the editor state and
nothing about a mouse. The MCP server calls the same procedures.
*/

/*
Open the set of a biome. A biome that fills flat has nothing to paint,
and says so instead of opening an empty grid.
*/
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

// The tile the author is painting.
tile_editor_tile :: proc(s: ^Sim) -> Tile_Id {
	return wang_tile_id(tile_editor_biome(s), s.tile_edit.sig, s.tile_edit.variant)
}

/*
Choose which tile of the set to paint.

A signature is four edge colors, and the variant says which drawing of
those four to work on. Both are wrapped rather than clamped, so a key
held down walks the set round and round.
*/
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

// The tile on screen, as an author reads it: the edge colors and the
// variant.
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

// Walk the set. Signature first, then variant, so one key reaches
// every tile.
tile_editor_step :: proc(s: ^Sim, delta: int) {
	e := &s.tile_edit
	if !e.open do return

	b := tile_editor_biome(s)
	index := (int(e.sig) * int(b.variants) + e.variant + delta) %% wang_set_size(b)
	e.sig = Wang_Signature(index / int(b.variants))
	e.variant = index %% int(b.variants)
}

/*
Paint one cell of the tile on screen.

A cell in the middle belongs to this tile. A cell in a border band
belongs to the edge color of that side, so the same stroke lands in
every tile that carries the color. That is the constraint the set
lives by, kept by the tool rather than by the author.

The result says whether anything changed, so the caller knows whether
the world behind it has to be generated again.
*/
tile_editor_paint_cell :: proc(s: ^Sim, x, y: i32, c: Cell) -> bool {
	e := &s.tile_edit
	if !e.open do return false
	if x < 0 || y < 0 || x >= TILE_SIZE || y >= TILE_SIZE do return false
	if int(c) >= len(s.world.materials.materials) do return false

	tile := tile_editor_tile(s)
	if tile_at(s.world.tiles, tile, x, y) == c do return false

	if wang_band(x, y) == .Inside {
		tile_set_cell(s.world.tiles, tile, x, y, c)
		return true
	}

	wang_paint_cell(s.world.tiles, tile_editor_biome(s), e.sig, x, y, c)

	// A seam stroke writes one value to a whole group, so it can only
	// mend a disagreement. Look again while there is one to mend.
	if e.conflict.found do tile_editor_refresh(s)
	return true
}

// Look for a cell two tiles of the set disagree about. This runs when
// a set opens and after a repair, not on every stroke: the editor
// cannot make a set disagree, only a pixel editor can.
tile_editor_refresh :: proc(s: ^Sim) {
	e := &s.tile_edit
	e.conflict = wang_find_conflict(s.world.tiles, tile_editor_biome(s))
}

tile_editor_can_save :: proc(s: ^Sim) -> bool {
	return !s.tile_edit.conflict.found
}

/*
Make the set agree with itself.

For every shared cell the first tile that holds it wins. It is the one
repair that needs no choice from the author, and it never touches the
middle of a tile, which is where the drawing is.
*/
tile_editor_normalize :: proc(s: ^Sim) -> (message: string, ok: bool) {
	e := &s.tile_edit
	if !e.open do return "no set is open", false

	changed := wang_normalize(s.world.tiles, tile_editor_biome(s))
	tile_editor_refresh(s)

	if changed == 0 do return "the seams already agree", true
	return fmt.tprintf("made %d seam cells agree", changed), true
}

/*
Write every file of the open set.

The save is blocked while two tiles disagree about a cell they share,
because that disagreement is a seam the world would show. The message
names the two files and the cell, and N is the way out.
*/
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

/*
A tile that could sit beyond one side of the tile on screen.

Every tile that fits a side shows the same cells along it, so the
first one found speaks for all of them. The editor draws its border
band beside the open tile, and that strip is exactly what the world
puts there.
*/
tile_editor_neighbour :: proc(s: ^Sim, band: Wang_Band) -> (tile: Tile_Id, found: bool) {
	e := &s.tile_edit
	b := tile_editor_biome(s)
	if b.tile_base == TILE_NONE do return 0, false

	for other in 0 ..< WANG_SIGNATURES {
		sig := Wang_Signature(other)
		fits := false

		// The neighbour meets this tile with its opposite side.
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

// Air is the material a transparent pixel loads as.
tile_editor_air :: proc(s: ^Sim) -> Cell {
	idx, found := find_material_index(s.world.materials, "Air")
	return found ? Cell(idx) : MATERIAL_AIR
}

// ------------------------------------------------------------
// The window half
// ------------------------------------------------------------

tile_editor_open :: proc(app: ^App, biome: Biome_Id) {
	message, ok := tile_editor_begin(&app.sim, biome)
	if !ok {
		editor_set_status(&app.sim, message, false)
		return
	}
	status_set(&app.tile_edit.status, message, true)

	app.tile_edit.saved_step = app.step
	app.tile_edit.saved_zoom = app.zoom

	// Show the world at native resolution, so every cell of it is on
	// screen instead of one sample in eight. A painted cell covers
	// TILE_SCALE of them, so it draws as a block of that size, which
	// is the size the paint really is. Forcing step to 1 alone is not
	// enough now that zoom exists: a zoom left above 1 would blow the
	// same oversized texels back up on screen, which is exactly what
	// forcing step to 1 is here to avoid.
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

// Which thumbnail of the set the mouse is over.
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

	// Pick a material. The number keys follow the palette order.
	for key, i in ([]rl.KeyboardKey{.ONE, .TWO, .THREE, .FOUR, .FIVE, .SIX, .SEVEN, .EIGHT, .NINE}) {
		if i < len(app.world.materials.materials) && rl.IsKeyPressed(key) {
			e.brush = Cell(i)
		}
	}

	// Walk the set.
	if rl.IsKeyPressed(.RIGHT_BRACKET) do tile_editor_step(&app.sim, 1)
	if rl.IsKeyPressed(.LEFT_BRACKET) do tile_editor_step(&app.sim, -1)
	if rl.IsKeyPressed(.V) {
		b := tile_editor_biome(&app.sim)
		tile_editor_select(&app.sim, int(e.sig), (e.variant + 1) %% int(b.variants))
	}

	if x, y, over := tile_editor_cell_under_mouse(); over {
		// Paint on press and on drag, so a stroke covers a run of cells.
		painted := false
		if rl.IsMouseButtonDown(.LEFT) {
			painted = tile_editor_paint_cell(&app.sim, x, y, e.brush)
		} else if rl.IsMouseButtonDown(.RIGHT) {
			// Erase is air, the way an empty pixel in the file is air.
			painted = tile_editor_paint_cell(&app.sim, x, y, tile_editor_air(&app.sim))
		}

		// The world behind the overlay follows the stroke at once.
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

	// Jump to a region the biome owns, so the paint is on screen.
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

/*
Point the camera at a region this biome owns.

The set draws through every region of the biome, so the first painted
map pixel is as good as any other. A biome nobody has painted yet has
nowhere to look at, and the editor says so rather than moving the
camera somewhere that shows a different biome.
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

// Color 0 and color 1, so an edge reads at a glance.
@(private = "file")
tile_editor_edge_paint :: proc(color: u8) -> rl.Color {
	return color == 0 ? rl.Color{78, 104, 150, 255} : rl.Color{226, 156, 62, 255}
}

tile_editor_draw :: proc(app: ^App) {
	if !app.tile_edit.open do return
	e := &app.tile_edit

	// Dim the world, but keep it visible. The point is to watch the
	// world change while you paint.
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

	// The gate, and why it is closed.
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

// Draw a rectangle of cells of one tile at a given scale.
@(private = "file")
tile_editor_draw_cells :: proc(
	app: ^App,
	tile: Tile_Id,
	x0, y0: i32, // top left on screen
	cx, cy: i32, // first cell of the tile to draw
	w, h: i32,   // how many cells
	scale: i32,
	sample: i32 = 1,
) {
	for y := i32(0); y < h; y += sample {
		for x := i32(0); x < w; x += sample {
			c := tile_at(app.world.tiles, tile, cx + x, cy + y)
			color := app.color_lut[c]
			if color.a == 0 do continue // air shows the checker behind

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

	// The frame holds the tile and the neighbour strips beside it.
	rl.DrawRectangle(
		TILE_VIEW_X - TILE_CONTEXT - 6,
		TILE_VIEW_Y - TILE_CONTEXT - 6,
		TILE_VIEW_SIZE + 2 * TILE_CONTEXT + 12,
		TILE_VIEW_SIZE + 2 * TILE_CONTEXT + 12,
		rl.Fade(rl.BLACK, 0.6),
	)
	tile_editor_draw_checker(TILE_VIEW_X, TILE_VIEW_Y, TILE_VIEW_SIZE, TILE_VIEW_SIZE)

	tile_editor_draw_cells(app, tile, TILE_VIEW_X, TILE_VIEW_Y, 0, 0, TILE_SIZE, TILE_SIZE, TILE_VIEW_CELL)

	// What the world puts beyond each side. Every tile that fits shows
	// the same cells there, so one of them stands for all of them.
	tile_editor_draw_context(app)

	// The bands belong to the edge colors, the middle belongs to this
	// tile. Mark where the free part starts.
	rl.DrawRectangleLines(
		TILE_VIEW_X + WANG_SEAM * TILE_VIEW_CELL,
		TILE_VIEW_Y + WANG_SEAM * TILE_VIEW_CELL,
		TILE_VIEW_SIZE - 2 * WANG_SEAM * TILE_VIEW_CELL,
		TILE_VIEW_SIZE - 2 * WANG_SEAM * TILE_VIEW_CELL,
		rl.Fade(rl.SKYBLUE, 0.5),
	)
	rl.DrawRectangleLines(TILE_VIEW_X, TILE_VIEW_Y, TILE_VIEW_SIZE, TILE_VIEW_SIZE, rl.Fade(rl.WHITE, 0.35))

	// The four edge colors, drawn on the sides they belong to.
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

/*
The whole set, as thumbnails.

The set is the unit of authoring now, so it is on screen the whole
time. Each thumbnail carries its four edge colors as a border, which
is the same border the big tile shows, and the tile in hand is lit.
*/
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
		tile_editor_draw_cells(app, tile, x, y, 0, 0, TILE_SIZE, TILE_SIZE, SET_SAMPLE, SET_SAMPLE)

		// The edge colors, as a border of four bars.
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

	// The variants of the tile in hand. One variant is the plain case,
	// and it still shows, so the count is never a surprise.
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
		tile_editor_draw_cells(app, tile, x, VARIANT_VIEW_Y, 0, 0, TILE_SIZE, TILE_SIZE, SET_SAMPLE, SET_SAMPLE)
		rl.DrawRectangleLines(
			x,
			VARIANT_VIEW_Y,
			SET_THUMB,
			SET_THUMB,
			v == e.variant ? rl.RAYWHITE : rl.Fade(rl.WHITE, 0.3),
		)
	}
}
