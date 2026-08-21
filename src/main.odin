package game

import "core:fmt"
import "core:os"
import "core:testing"
import rl "vendor:raylib"

WINDOW_W :: 1280
WINDOW_H :: 720

WORLD_VIEW_MAX_STEP :: 256
WORLD_VIEW_MAX_ZOOM :: 4

PLAYER_MAX_CATCHUP_STEPS :: 5

PLAYER_CAMERA_DEAD_ZONE :: 32
App :: struct {
	using sim: Sim,

	cam_x: i32,
	cam_y: i32,
	step:  i32,
	zoom:  i32,

	tick_accum: f64,

	cells:     []Cell,
	pixels:    []rl.Color,
	texture:   rl.Texture2D,

	sprite:         Sprite_Sheet,
	sprite_texture: rl.Texture2D,

	color_lut: [256]rl.Color,

	dirty: bool,
}

BACKGROUND :: rl.Color{18, 20, 26, 255}

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

app_load_data :: proc(app: ^App) -> bool {
	if err := sim_load(&app.sim); err != .None do return false

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

	rl.SetTextureFilter(app.texture, .POINT)

	sheet, result := load_sprite_sheet(SPRITE_SHEET_PATH)
	if result.err != .None {
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

app_view_cells :: proc(app: ^App) -> (w, h: i32) {
	return WINDOW_W / app.zoom, WINDOW_H / app.zoom
}

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

@(private = "file")
app_handle_free_camera :: proc(app: ^App) {
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

@(private = "file")
app_zoom_step :: proc(app: ^App, dir: i32) -> bool {
	if dir < 0 {
		if app.step > 1 {
			app.step /= 2
			return true
		}
		if app.zoom < WORLD_VIEW_MAX_ZOOM {
			app.zoom *= 2
			return true
		}
	} else if dir > 0 {
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

@(private = "file")
app_cursor_cell :: proc(app: ^App) -> (x, y: i32) {
	m := rl.GetMousePosition()
	scale := f32(app.zoom) / f32(app.step)
	return app.cam_x + i32(m.x / scale), app.cam_y + i32(m.y / scale)
}

@(private = "file")
app_handle_play :: proc(app: ^App) {
	held: Player_Input
	if rl.IsKeyDown(.A) || rl.IsKeyDown(.LEFT) do held += {.Left}
	if rl.IsKeyDown(.D) || rl.IsKeyDown(.RIGHT) do held += {.Right}
	if rl.IsKeyDown(.LEFT_SHIFT) || rl.IsKeyDown(.RIGHT_SHIFT) do held += {.Run}
	if rl.IsKeyDown(.SPACE) || rl.IsKeyDown(.W) || rl.IsKeyDown(.UP) do held += {.Jump}
	if rl.IsKeyDown(.E) || rl.IsMouseButtonDown(.LEFT) do held += {.Dig}

	jump_pressed := rl.IsKeyPressed(.SPACE) || rl.IsKeyPressed(.W) || rl.IsKeyPressed(.UP)

	cursor_x, cursor_y := app_cursor_cell(app)
	centre_x, centre_y := player_centre(app.player)
	aim := player_aim_of(f32(cursor_x - centre_x), f32(cursor_y - centre_y))

	app_step_player(app, rl.GetFrameTime(), held, jump_pressed, aim)
	app_follow_player(app)

	if zoom_dir := app_read_zoom_dir(); zoom_dir != 0 {
		app_apply_zoom(app, zoom_dir)
	}
}

@(private = "file")
app_step_player :: proc(app: ^App, dt: f32, held: Player_Input, jump_pressed: bool, aim: u8) {
	tick_dt : f64 = 1.0 / f64(PLAYER_TICK_HZ)
	app.tick_accum += f64(dt)

	steps := 0
	jp := jump_pressed
	for app.tick_accum >= tick_dt && steps < PLAYER_MAX_CATCHUP_STEPS {
		sim_step_player(&app.sim, held, jp, aim)
		sandbox_step(&app.sandbox, app.world.materials)
		app.tick_accum -= tick_dt
		jp = false
		steps += 1
	}
	if steps == PLAYER_MAX_CATCHUP_STEPS {
		app.tick_accum = 0
	}
}

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

@(private = "file")
app_draw_player :: proc(app: ^App) {
	if app.sprite.pixels == nil do return

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

@(private = "file")
app_draw_beam :: proc(app: ^App) {
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
	rl.DrawLineEx(from, to, max(scale, 1), BEAM_CORE)
}

draw_hud :: proc(app: ^App) {
	if app.editor.open || app.tile_edit.open do return

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
			app_zoom_step(&app, -1)
			check(t, &app)
		}
		for _ in 0 ..< 20 {
			app_zoom_step(&app, 1)
			check(t, &app)
		}
	}
}

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
