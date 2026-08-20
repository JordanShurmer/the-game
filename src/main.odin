package game

import "core:fmt"
import "core:os"
import "core:testing"
import rl "vendor:raylib"

/*
The game window.

The world view is a texture the size of the window, but not always
filled that far. One texel is `step` world cells, and one screen pixel
is `1/zoom` of a texel; only one of step and zoom is ever above 1, so
the app asks the generator for exactly `app_view_cells` texels and
`rl.DrawTexturePro` blows the result up to the window. There is no
chunk store yet, because nothing needs one. See docs/player.md, "A
view the wizard is visible in", for the full ladder.
*/

WINDOW_W :: 1280
WINDOW_H :: 720

// The ends of the zoom ladder. 1280 and 720 divide evenly only by 1, 2
// and 4, so zoom stops at 4: a non-integer scale in a pixel game leaves
// an uneven grid. step has no such ceiling of its own, but 256 is far
// past anything a shipped view needs and stops a stuck key from
// growing it without bound.
WORLD_VIEW_MAX_STEP :: 256
WORLD_VIEW_MAX_ZOOM :: 4

// A frame that runs long must still advance the wizard by whole ticks,
// never a fraction of one, but a stall long enough to hit this cap is
// not owed the rest of its backlog. See app_step_player.
PLAYER_MAX_CATCHUP_STEPS :: 5

// How far the wizard can drift from the centre of the screen before
// the camera follows him. Big enough that a step or a hop does not
// pan the world; small enough that he is never far from the middle of
// it. See app_follow_player.
PLAYER_CAMERA_DEAD_ZONE :: 32 // cells

/*
The window state.

Everything the game knows lives in the Sim. The App adds what only a
window needs: a camera, two buffers, a texture, and the wizard's
picture. The MCP server drives the same Sim with none of that, so the
two cannot drift apart.
*/
App :: struct {
	using sim: Sim,

	// Camera. cam_x and cam_y are the world cell at the top-left texel.
	cam_x: i32,
	cam_y: i32,
	step:  i32, // world cells per texel, 1 or more
	zoom:  i32, // screen pixels per texel, 1, 2 or 4; see the ladder above

	// The wizard's fixed-step accumulator. SetTargetFPS is a target,
	// not a guarantee, so a frame that runs long or short must still
	// advance him by whole PLAYER_TICK_HZ ticks. See app_step_player.
	tick_accum: f64,

	// The view buffers. cells holds material ids; pixels holds what
	// the texture shows. Both are the size of the window, allocated
	// once; only the first app_view_cells() rectangle of either is
	// live at any zoom above 1.
	cells:     []Cell,
	pixels:    []rl.Color,
	texture:   rl.Texture2D,

	// The wizard's picture: one sheet and the texture it uploads to,
	// loaded once for the life of the window because both need one to
	// exist at all.
	sprite:         Sprite_Sheet,
	sprite_texture: rl.Texture2D,

	// A material id maps to a color through this table. It is small
	// and read once per texel, so it stays hot.
	color_lut: [256]rl.Color,

	dirty: bool,
}

BACKGROUND :: rl.Color{18, 20, 26, 255}

// The plasma beam: a wide dim sheath and a thin bright core, which is
// what reads as hot at any zoom. See app_draw_beam.
BEAM_GLOW :: rl.Color{110, 210, 255, 255}
BEAM_CORE :: rl.Color{236, 250, 255, 255}

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

		// While play is following him, the sandbox is alive: sand
		// falls and fire spreads with no camera move at all, so the
		// view has to be redrawn every frame, not only when app.dirty
		// says the camera moved. The editors pause this: they read the
		// static generated world, and app.dirty already drives them.
		playing := !app.editor.open && !app.tile_edit.open
		if app.dirty || (playing && app.follow_player) {
			app_regenerate(&app)
			app.dirty = false
		}

		w, h := app_view_cells(&app)

		rl.BeginDrawing()
		rl.ClearBackground(BACKGROUND)
		rl.DrawTexturePro(
			app.texture,
			rl.Rectangle{0, 0, f32(w), f32(h)},
			rl.Rectangle{0, 0, WINDOW_W, WINDOW_H},
			rl.Vector2{0, 0},
			0,
			rl.WHITE,
		)
		app_draw_player(&app)
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
world the same way, and it is what spawns the wizard. Play opens
centred on him, not on the world origin: docs/player.md's ladder
starts at zoom 4, step 1, 320 by 180 cells on screen.
*/
app_load_data :: proc(app: ^App) -> bool {
	if err := sim_load(&app.sim); err != .None do return false

	// The play sandbox follows him from here on: docs/physics.md, "The
	// wizard meets the sandbox". sim_load itself never turns this on,
	// so the MCP server and every test that opens a sandbox by hand
	// still get exactly the sandbox they asked for.
	sim_play_begin(&app.sim)

	for m, i in app.world.materials.materials {
		app.color_lut[i] = rl_from_argb(m.color)
	}

	app.step = 1
	app.zoom = WORLD_VIEW_MAX_ZOOM
	w, h := app_view_cells(app)
	app.cam_x = i32(app.player.x) - (w * app.step) / 2
	app.cam_y = i32(app.player.y) - (h * app.step) / 2
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

	// Nearest neighbour, not the default bilinear filter: zoom draws
	// one texel as a solid zoom by zoom block of screen pixels, and a
	// smoothing filter would blur the seam between texels into a soft
	// grey line instead of the crisp grid a pixel game wants.
	rl.SetTextureFilter(app.texture, .POINT)

	sheet, result := load_sprite_sheet(SPRITE_SHEET_PATH)
	if result.err != .None {
		// Not fatal: the world still loads and plays, just with no
		// wizard drawn. app_draw_player checks for this same failure.
		fmt.eprintfln("the sprite sheet could not load: %v", result.err)
	}
	app.sprite = sheet

	if sheet.pixels != nil {
		img := rl.Image {
			data    = raw_data(sheet.pixels),
			width   = sheet.width,
			height  = sheet.height,
			mipmaps = 1,
			format  = .UNCOMPRESSED_R8G8B8A8,
		}
		app.sprite_texture = rl.LoadTextureFromImage(img)
		rl.SetTextureFilter(app.sprite_texture, .POINT)
	}
}

app_destroy_view :: proc(app: ^App) {
	rl.UnloadTexture(app.sprite_texture)
	destroy_sprite_sheet(app.sprite)
	rl.UnloadTexture(app.texture)
	delete(app.cells)
	delete(app.pixels)
}

// The visible extent of the world view, in texels: WINDOW_W/zoom by
// WINDOW_H/zoom. The buffers stay allocated at the window's full size
// regardless, so every site that once assumed the view was WINDOW_W by
// WINDOW_H texels (true only at zoom 1) reads this instead.
app_view_cells :: proc(app: ^App) -> (w, h: i32) {
	return WINDOW_W / app.zoom, WINDOW_H / app.zoom
}

/*
Generate what the window shows, then turn material ids into colors.

This is the one generate path. The editor calls it after every paint
stroke, and the game calls it after every camera move, and now after
every physics tick too while play is following: the sandbox is what
he actually collides with, and a view that only ever redrew the
generator would show him standing on a picture again.

Only the visible w by h texels are asked for and converted, not the
whole WINDOW_W by WINDOW_H buffer: at zoom 4 that is 57600 texels
converted instead of 921600. generate writes rows of exactly `w`, so
the first w*h entries of app.cells are already the tightly packed w by
h rectangle rl.UpdateTextureRec wants; there is nothing to repack.
app_draw_sandbox below holds to the same w*h bound, so drawing the
sandbox over the view costs no more than drawing the view itself did.
*/
app_regenerate :: proc(app: ^App) {
	w, h := app_view_cells(app)
	view := World_View {
		x    = app.cam_x,
		y    = app.cam_y,
		w    = w,
		h    = h,
		step = app.step,
	}
	generate(app.world, view, app.cells)
	if app.follow_player do app_draw_sandbox(app, view)

	count := int(w) * int(h)
	for i in 0 ..< count {
		app.pixels[i] = app.color_lut[app.cells[i]]
	}
	rl.UpdateTextureRec(app.texture, rl.Rectangle{0, 0, f32(w), f32(h)}, raw_data(app.pixels))
}

/*
Overwrite the generated view with the running sandbox, wherever the
two cover the same ground. This is the join made visible: the
generator draws the picture, and the sandbox is what actually moves
under the wizard's feet, so what the window shows has to be the
second one wherever it exists.

Bounded to the same w by h texels app_regenerate already asked for, at
whatever step the view is sampled at: a texel that falls outside the
sandbox rectangle is left as the generator drew it.
*/
@(private = "file")
app_draw_sandbox :: proc(app: ^App, view: World_View) {
	sb := &app.sandbox
	for ty in i32(0) ..< view.h {
		wy := view.y + ty * view.step
		sy := wy - sb.origin_y
		if sy < 0 || sy >= sb.height do continue

		row := app.cells[int(ty) * int(view.w):][:view.w]
		for tx in i32(0) ..< view.w {
			wx := view.x + tx * view.step
			sx := wx - sb.origin_x
			if sx < 0 || sx >= sb.width do continue
			row[tx] = sandbox_cell(sb, sx, sy)
		}
	}
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
		app_handle_free_camera(app)
		return
	}

	app_handle_play(app)
}

// WASD/arrows pan and wheel/-/= zoom: the free camera the world editor
// opens onto, same as it worked before the wizard existed. Play, below,
// hands the same keys to him instead and lets the camera follow.
@(private = "file")
app_handle_free_camera :: proc(app: ^App) {
	// The speed follows the zoom, so the world moves at the same rate on
	// screen whatever the step is.
	pan := 8 * app.step
	moved := false
	if rl.IsKeyDown(.LEFT) || rl.IsKeyDown(.A) {app.cam_x -= pan;moved = true}
	if rl.IsKeyDown(.RIGHT) || rl.IsKeyDown(.D) {app.cam_x += pan;moved = true}
	if rl.IsKeyDown(.UP) || rl.IsKeyDown(.W) {app.cam_y -= pan;moved = true}
	if rl.IsKeyDown(.DOWN) || rl.IsKeyDown(.S) {app.cam_y += pan;moved = true}
	if moved do app.dirty = true

	if zoom_dir := app_read_zoom_dir(); zoom_dir != 0 {
		app_apply_zoom(app, zoom_dir)
	}
}

// -1 zooms in, +1 zooms out, 0 is neither. Read once and shared by the
// editor's free camera and by play, so the two keys mean the same
// thing in both places.
@(private = "file")
app_read_zoom_dir :: proc() -> i32 {
	zoom_dir : i32 = 0
	if rl.IsKeyPressed(.EQUAL) || rl.IsKeyPressed(.KP_ADD) do zoom_dir = -1
	if rl.IsKeyPressed(.MINUS) || rl.IsKeyPressed(.KP_SUBTRACT) do zoom_dir = 1
	if wheel := rl.GetMouseWheelMove(); wheel > 0 {
		zoom_dir = -1
	} else if wheel < 0 {
		zoom_dir = 1
	}
	return zoom_dir
}

/*
One rung of the ladder docs/player.md draws out:

    ... 4     2     1     1     1      step
        1     1     1     2     4      zoom
      <- out                   in ->

Zooming in shrinks step toward 1, then grows zoom toward 4. Zooming out
walks the same path backward. Only one of the two is ever above 1 at a
time, which is what the two separate `if`s below hold: each only ever
touches the field that is not already stuck at its floor of 1.
*/
@(private = "file")
app_zoom_step :: proc(app: ^App, dir: i32) -> bool {
	if dir < 0 { // toward the wizard
		if app.step > 1 {
			app.step /= 2
			return true
		}
		if app.zoom < WORLD_VIEW_MAX_ZOOM {
			app.zoom *= 2
			return true
		}
	} else if dir > 0 { // away from him
		if app.zoom > 1 {
			app.zoom /= 2
			return true
		}
		if app.step < WORLD_VIEW_MAX_STEP {
			app.step *= 2
			return true
		}
	}
	return false
}

// Change the zoom about the middle of the window, so the view does not
// jump: read the world cell under the centre before the change, then
// put that same cell back under the centre after.
@(private = "file")
app_apply_zoom :: proc(app: ^App, dir: i32) {
	old_w, old_h := app_view_cells(app)
	centre_x := app.cam_x + (old_w * app.step) / 2
	centre_y := app.cam_y + (old_h * app.step) / 2

	if !app_zoom_step(app, dir) do return

	new_w, new_h := app_view_cells(app)
	app.cam_x = centre_x - (new_w * app.step) / 2
	app.cam_y = centre_y - (new_h * app.step) / 2
	app.dirty = true
}

/*
Where the cursor is, in world cells.

This is the inverse of the one transform the whole view is drawn
through. rl.DrawTexturePro blows app_view_cells texels up to the whole
window, so a screen pixel is zoom/step of a world cell and the scale
here is the same number app_draw_player and app_draw_beam scale by.
*/
@(private = "file")
app_cursor_cell :: proc(app: ^App) -> (x, y: i32) {
	m := rl.GetMousePosition()
	scale := f32(app.zoom) / f32(app.step)
	return app.cam_x + i32(m.x / scale), app.cam_y + i32(m.y / scale)
}

/*
Play: A/D or LEFT/RIGHT walk, SHIFT runs, SPACE/W/UP jumps and, held in
the air, flies, E or the left mouse button digs, and the cursor points
the digger. Wheel and -/= still zoom; docs/player.md lists zoom as a
control of its own, not one the editor owns alone.
*/
@(private = "file")
app_handle_play :: proc(app: ^App) {
	held: Player_Input
	if rl.IsKeyDown(.A) || rl.IsKeyDown(.LEFT) do held += {.Left}
	if rl.IsKeyDown(.D) || rl.IsKeyDown(.RIGHT) do held += {.Right}
	if rl.IsKeyDown(.LEFT_SHIFT) || rl.IsKeyDown(.RIGHT_SHIFT) do held += {.Run}
	if rl.IsKeyDown(.SPACE) || rl.IsKeyDown(.W) || rl.IsKeyDown(.UP) do held += {.Jump}
	if rl.IsKeyDown(.E) || rl.IsMouseButtonDown(.LEFT) do held += {.Dig}

	// The edge, not the level: player_step reads a press as a launch and
	// a held key in the air, past its delay, as the jetpack. Collapsing
	// the two into IsKeyDown alone would mean a held key always flies,
	// and there would be no jump at all.
	jump_pressed := rl.IsKeyPressed(.SPACE) || rl.IsKeyPressed(.W) || rl.IsKeyPressed(.UP)

	// The beam comes out of the centre of his mass, so the aim is
	// measured from there and not from his feet: measured from the
	// feet, a cursor level with his chest would point the tool at the
	// floor. player_centre is the one place that point is decided.
	cursor_x, cursor_y := app_cursor_cell(app)
	centre_x, centre_y := player_centre(app.player)
	aim := player_aim_of(f32(cursor_x - centre_x), f32(cursor_y - centre_y))

	app_step_player(app, rl.GetFrameTime(), held, jump_pressed, aim)
	app_follow_player(app)

	if zoom_dir := app_read_zoom_dir(); zoom_dir != 0 {
		app_apply_zoom(app, zoom_dir)
	}
}

/*
Run the wizard a whole number of PLAYER_TICK_HZ ticks for this frame's
elapsed time, not a fraction of one. SetTargetFPS is a target, not a
guarantee, and a slow frame must not slow him down.

The catch-up is capped at PLAYER_MAX_CATCHUP_STEPS. A long stall (a
breakpoint, a slow load) would otherwise queue a large backlog and
either freeze the game paying it all off in one frame, or spread it
across many later frames as a slow-motion catch-up nobody asked for.
Past the cap the remainder is dropped instead: a hitch is the honest
cost of a stall, not a debt the sim carries forward.
*/
@(private = "file")
app_step_player :: proc(app: ^App, dt: f32, held: Player_Input, jump_pressed: bool, aim: u8) {
	tick_dt : f64 = 1.0 / f64(PLAYER_TICK_HZ)
	app.tick_accum += f64(dt)

	steps := 0
	jp := jump_pressed
	for app.tick_accum >= tick_dt && steps < PLAYER_MAX_CATCHUP_STEPS {
		sim_step_player(&app.sim, held, jp, aim)
		// Physics and the wizard advance together, one sandbox tick per
		// player tick: docs/physics.md, "The window shows the physics".
		// sim_run does this for the queue's own ticks; the window's
		// direct path into sim_step_player has to do it itself.
		sandbox_step(&app.sandbox, app.world.materials)
		app.tick_accum -= tick_dt
		jp = false // the press is one tick's edge, not every catch-up tick's
		steps += 1
	}
	if steps == PLAYER_MAX_CATCHUP_STEPS {
		app.tick_accum = 0
	}
}

/*
Keep the wizard inside a dead zone around the centre of the screen,
rather than pinning him to it exactly. dirty is set only when cam_x or
cam_y actually change, so a standing player does not regenerate the
screen sixty times a second: his position does not move, so the target
centre does not move, so the distance from it never crosses the dead
zone in the first place.
*/
@(private = "file")
app_follow_player :: proc(app: ^App) {
	w, h := app_view_cells(app)
	centre_x := app.cam_x + (w * app.step) / 2
	centre_y := app.cam_y + (h * app.step) / 2
	dead := PLAYER_CAMERA_DEAD_ZONE * app.step

	px := i32(app.player.x)
	py := i32(app.player.y)

	new_cam_x := app.cam_x
	if px - centre_x > dead {
		new_cam_x += px - centre_x - dead
	} else if px - centre_x < -dead {
		new_cam_x += px - centre_x + dead
	}

	new_cam_y := app.cam_y
	if py - centre_y > dead {
		new_cam_y += py - centre_y - dead
	} else if py - centre_y < -dead {
		new_cam_y += py - centre_y + dead
	}

	if new_cam_x != app.cam_x || new_cam_y != app.cam_y {
		app.cam_x = new_cam_x
		app.cam_y = new_cam_y
		app.dirty = true
	}
}

/*
Draw the wizard where the camera puts him: his frame's world origin,
run through the same cam_x/cam_y/step/zoom the terrain draws through
and scaled by zoom/step, so he tracks the same ground the terrain
shows. facing flips the source rectangle's width rather than the
picture, the same mirror sprite_pixel does for bin/shot, done here by
the GPU instead of pixel by pixel.
*/
@(private = "file")
app_draw_player :: proc(app: ^App) {
	if app.sprite.pixels == nil do return // the sheet failed to load; see app_init_view

	p := app.player
	motion := player_motion(p)
	column := sprite_frame(motion, p.anim)

	src := rl.Rectangle {
		x      = f32(column * SPRITE_FRAME_W),
		y      = f32(int(motion) * SPRITE_FRAME_H),
		width  = f32(SPRITE_FRAME_W) * f32(p.facing),
		height = f32(SPRITE_FRAME_H),
	}

	origin_x, origin_y := sprite_frame_origin(p)
	scale := f32(app.zoom) / f32(app.step)
	dst := rl.Rectangle {
		x      = f32(origin_x - app.cam_x) * scale,
		y      = f32(origin_y - app.cam_y) * scale,
		width  = f32(SPRITE_FRAME_W) * scale,
		height = f32(SPRITE_FRAME_H) * scale,
	}

	rl.DrawTexturePro(app.sprite_texture, src, dst, rl.Vector2{0, 0}, 0, rl.WHITE)
	app_draw_beam(app)
}

/*
The plasma beam, while he holds the button down.

The cut itself is already on the screen: player_dig cleared those
cells and app_draw_sandbox draws what the sandbox holds. What is
missing without this is the tool. A hole that opens with nothing
joining it to the man reads as the world breaking, not as him working,
and the beam is what says which of the two it is.

Two lines, not one. The sheath is the width of the kerf and nearly
transparent, so it shows what the beam is about to take; the core is
one cell wide and almost white, which is what reads as hot. Both are
drawn through the same scale the terrain and the wizard are, so the
beam lands on the cells it actually cut.
*/
@(private = "file")
app_draw_beam :: proc(app: ^App) {
	// The beam is a picture of a button being held, and no button is
	// held while an editor is open: player_step is the only thing that
	// writes p.digging, and the editors are the two places that do not
	// call it. Without this the last beam of play hangs across the
	// editor until the next tick of play clears it.
	if app.editor.open || app.tile_edit.open do return

	p := app.player
	if !p.digging do return

	scale := f32(app.zoom) / f32(app.step)
	cx, cy := player_centre(p)
	dx, dy := player_aim_vector(p.aim)

	from := rl.Vector2{f32(cx - app.cam_x) * scale, f32(cy - app.cam_y) * scale}
	to := rl.Vector2 {
		from.x + dx * f32(PLAYER_DIG_RANGE) * scale,
		from.y + dy * f32(PLAYER_DIG_RANGE) * scale,
	}

	rl.DrawLineEx(from, to, f32(PLAYER_DIG_WIDTH) * scale, rl.Fade(BEAM_GLOW, 0.18))
	// At least one screen pixel: zoomed all the way out, a core a
	// fraction of a pixel wide would not be drawn at all.
	rl.DrawLineEx(from, to, max(scale, 1), BEAM_CORE)
}

draw_hud :: proc(app: ^App) {
	if app.editor.open || app.tile_edit.open do return

	// The view is app_view_cells texels wide, not WINDOW_W: at zoom
	// above 1 that is fewer texels than the window has pixels, and the
	// centre computed from WINDOW_W would name the wrong cell and the
	// wrong biome.
	w, h := app_view_cells(app)
	cx := app.cam_x + (w / 2) * app.step
	cy := app.cam_y + (h / 2) * app.step
	id := world_biome_at(app.world, cx, cy)
	b := app.world.biomes.biomes[id]

	rl.DrawRectangle(0, 0, 460, 130, rl.Fade(rl.BLACK, 0.55))
	rl.DrawText(fmt.ctprintf("centre %d, %d   %d cell/texel   %dx zoom", cx, cy, app.step, app.zoom), 12, 10, 18, rl.RAYWHITE)
	rl.DrawText(
		fmt.ctprintf("biome at centre: %s", app.world.biomes.names[id]),
		12,
		32,
		18,
		rl_from_argb(b.key_color),
	)

	// What the cell under the crosshair is made of. A tiled biome shows
	// a different material every few cells, so the biome name alone no
	// longer says what you are looking at. Naming the tile as well says
	// which file to open to change it.
	cell := world_cell_at(app.world, cx, cy)
	source := "fill"
	if b.tile_base != TILE_NONE {
		sig := wang_signature_at(app.world.seed, tile_slot(cx), tile_slot(cy))
		source = fmt.tprintf(
			"tile %d%d%d%d",
			wang_north(sig),
			wang_east(sig),
			wang_south(sig),
			wang_west(sig),
		)
	}
	rl.DrawText(
		fmt.ctprintf("material: %s (%s)", app.world.materials.names[cell], source),
		12,
		54,
		18,
		rl_from_argb(app.world.materials.materials[cell].color | 0xFF000000),
	)

	// The wizard: where he stands, whether the ground is under him, and
	// the jetpack tank, so a burn running dry does not come as a
	// surprise.
	p := app.player
	ground := p.on_ground ? "on ground" : "airborne"
	rl.DrawText(
		fmt.ctprintf("wizard %d, %d   %s   fuel %d%%", i32(p.x), i32(p.y), ground, i32(p.fuel * 100 + 0.5)),
		12,
		76,
		18,
		rl.RAYWHITE,
	)

	rl.DrawText("A D walk   SHIFT run   SPACE/W/UP jump, hold to fly   E/click dig where you point   wheel zoom   TAB world editor", 12, 100, 16, rl.GRAY)
}

// ------------------------------------------------------------
// Tests (run with: odin test src  from repo root)
// ------------------------------------------------------------

@(test)
test_app_view_cells_shrinks_with_zoom :: proc(t: ^testing.T) {
	app: App
	app.zoom = 1
	w, h := app_view_cells(&app)
	testing.expectf(t, w == WINDOW_W && h == WINDOW_H, "at zoom 1 the view must be the whole window, got %dx%d", w, h)

	app.zoom = 2
	w, h = app_view_cells(&app)
	testing.expectf(t, w == WINDOW_W / 2 && h == WINDOW_H / 2, "at zoom 2 the view must be half the window, got %dx%d", w, h)

	app.zoom = 4
	w, h = app_view_cells(&app)
	testing.expectf(
		t, w == 320 && h == 180,
		"at zoom 4 the view must be 320x180, the size docs/player.md names, got %dx%d", w, h,
	)
}

/*
Walks the ladder all the way in and all the way out, from every rung it
could plausibly start on, and holds two invariants at every step: zoom
is always 1, 2 or 4 (never 3, since 1280 and 720 divide evenly only by
those), and step never falls under 1. A ladder that ever let both climb
above 1 at once would also make app_view_cells and the step conversion
disagree about how large a texel is.
*/
@(test)
test_the_zoom_ladder_never_produces_zoom_3_or_a_step_below_1 :: proc(t: ^testing.T) {
	starts := []struct{step, zoom: i32}{
		{step = 1, zoom = 1},
		{step = 1, zoom = 4},
		{step = 8, zoom = 1},
		{step = 256, zoom = 1},
	}

	check :: proc(t: ^testing.T, app: ^App) {
		testing.expectf(t, app.step >= 1, "step must never fall below 1, got %d", app.step)
		testing.expectf(
			t, app.zoom == 1 || app.zoom == 2 || app.zoom == 4,
			"zoom must be 1, 2 or 4 and never 3, got %d", app.zoom,
		)
		testing.expectf(
			t, app.step == 1 || app.zoom == 1,
			"step and zoom must never both be above 1 at once, got step=%d zoom=%d", app.step, app.zoom,
		)
	}

	for start in starts {
		app: App
		app.step = start.step
		app.zoom = start.zoom

		for _ in 0 ..< 20 {
			app_zoom_step(&app, -1) // all the way in
			check(t, &app)
		}
		for _ in 0 ..< 20 {
			app_zoom_step(&app, 1) // all the way back out
			check(t, &app)
		}
	}
}

// A rung that changes must actually change the view, or a key press
// would read as pressed and do nothing.
@(test)
test_zooming_in_from_the_default_start_shrinks_the_view :: proc(t: ^testing.T) {
	app: App
	app.step = 1
	app.zoom = 1
	before_w, before_h := app_view_cells(&app)

	changed := app_zoom_step(&app, -1)
	testing.expect(t, changed, "zooming in from step=1 zoom=1 must move the ladder")

	after_w, after_h := app_view_cells(&app)
	testing.expectf(
		t, after_w < before_w && after_h < before_h,
		"zooming in must shrink the visible texel extent, got %dx%d from %dx%d", after_w, after_h, before_w, before_h,
	)
}
