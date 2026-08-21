package game

import "core:fmt"
import "core:math"
import "core:os"
import "core:strconv"
import "core:strings"
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

	water:     Water,
	water_run: []u8,

	sprite:         Sprite_Sheet,
	sprite_texture: rl.Texture2D,

	color_lut: [256]rl.Color,

	dirty: bool,
}

WINDOW_SHOT_FRAMES :: 90

Window_Shot :: struct {
	path:   string,
	frames: int,
	walk:   int,
	throw:  bool,
	aim:    u8,
	ticks:  int,
	on:     bool,
}

BACKGROUND :: rl.Color{18, 20, 26, 255}

BEAM_GLOW :: rl.Color{110, 210, 255, 255}
BEAM_CORE :: rl.Color{236, 250, 255, 255}

main :: proc() {
	shot := read_window_shot(os.args[1:])

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

	if shot.on do app_walk(&app, shot.walk)
	if shot.on && shot.throw do app_throw(&app, shot.aim, shot.ticks)

	frames := 0
	for !rl.WindowShouldClose() {
		if !shot.on do app_handle_input(&app)

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
		app_draw_water(&app, w, h)
		app_draw_crystals(&app)
		app_draw_fireflies(&app)
		app_draw_pots(&app)
		app_draw_bangs(&app)
		app_draw_player(&app)
		draw_hud(&app)
		editor_draw(&app)
		tile_editor_draw(&app)
		rl.EndDrawing()

		frames += 1
		if shot.on && frames >= shot.frames {
			rl.TakeScreenshot(strings.clone_to_cstring(shot.path, context.temp_allocator))
			free_all(context.temp_allocator)
			break
		}

		free_all(context.temp_allocator)
	}
}

read_window_shot :: proc(args: []string) -> (shot: Window_Shot) {
	shot.frames = WINDOW_SHOT_FRAMES

	for arg in args {
		split := strings.index_byte(arg, '=')
		if split < 0 do continue
		key := arg[:split]
		value := arg[split + 1:]

		switch key {
		case "shot":
			shot.path = value
			shot.on = true
		case "frames":
			if n, ok := strconv.parse_int(value); ok do shot.frames = max(n, 1)
		case "walk":
			if n, ok := strconv.parse_int(value); ok do shot.walk = n
		case "throw":
			if n, ok := strconv.parse_int(value); ok {
				shot.throw = true
				shot.aim = u8(i32(math.round(f32(n) / 360 * 256)) & 255)
			}
		case "ticks":
			if n, ok := strconv.parse_int(value); ok do shot.ticks = max(n, 0)
		}
	}
	return shot
}

@(private = "file")
app_walk :: proc(app: ^App, ticks: int) {
	held: Player_Input = ticks < 0 ? {.Left} : {.Right}

	for _ in 0 ..< abs(ticks) {
		sim_step_player(&app.sim, held, false)
		sandbox_step(&app.sandbox, app.world.materials)
	}
	app_follow_player(app)
	app.dirty = true
}

@(private = "file")
app_throw :: proc(app: ^App, aim: u8, ticks: int) {
	sim_step_player(&app.sim, {.Throw}, false, aim)
	sandbox_step(&app.sandbox, app.world.materials)

	for _ in 0 ..< ticks {
		sim_step_player(&app.sim, {}, false, aim)
		sandbox_step(&app.sandbox, app.world.materials)
	}
	app_follow_player(app)
	app.dirty = true
}

app_load_data :: proc(app: ^App) -> bool {
	if err := sim_load(&app.sim); err != .None do return false

	sim_play_begin(&app.sim)

	for m, i in app.world.materials.materials {
		app.color_lut[i] = blend_over(rl_from_argb(m.color), BACKGROUND)
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
	app.water_run = make([]u8, WINDOW_W)

	blank := rl.Image {
		data    = raw_data(app.pixels),
		width   = WINDOW_W,
		height  = WINDOW_H,
		mipmaps = 1,
		format  = .UNCOMPRESSED_R8G8B8A8,
	}
	app.texture = rl.LoadTextureFromImage(blank)

	rl.SetTextureFilter(app.texture, .POINT)

	app.water = water_load(app.world.materials, WINDOW_W, WINDOW_H)
	if !app.water.on {
		fmt.eprintfln("%s did not load: the water is drawn flat", WATER_SHADER_PATH)
	}

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
	water_unload(&app.water)
	rl.UnloadTexture(app.texture)
	delete(app.cells)
	delete(app.pixels)
	delete(app.water_run)
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

	if app_lighting(app) {
		app_shade(app, view)
	} else {
		count := int(w) * int(h)
		for i in 0 ..< count {
			app.pixels[i] = app.color_lut[app.cells[i]]
		}
	}
	rl.UpdateTextureRec(app.texture, rl.Rectangle{0, 0, f32(w), f32(h)}, raw_data(app.pixels))
	if app_lighting(app) do water_mark(&app.water, app.cells, w, h, app.water_run)
}

app_lighting :: proc(app: ^App) -> bool {
	return app.follow_player && !app.editor.open && !app.tile_edit.open
}

@(private = "file")
app_shade :: proc(app: ^App, view: World_View) {
	for ty in i32(0) ..< view.h {
		wy := view.y + ty * view.step
		row := app.cells[int(ty) * int(view.w):][:view.w]
		out := app.pixels[int(ty) * int(view.w):][:view.w]

		for tx in i32(0) ..< view.w {
			wx := view.x + tx * view.step
			out[tx] = light_shade(app.color_lut[row[tx]], light_lux(&app.light, wx, wy))
		}
	}
}

@(private = "file")
app_draw_water :: proc(app: ^App, w, h: i32) {
	if !app_lighting(app) do return

	water_begin(
		&app.water,
		{WINDOW_W, WINDOW_H},
		{f32(app.cam_x), f32(app.cam_y)},
		f32(app.step),
		f32(rl.GetTime()),
	)
	rl.DrawTexturePro(
		app.texture,
		rl.Rectangle{0, 0, f32(w), f32(h)},
		rl.Rectangle{0, 0, WINDOW_W, WINDOW_H},
		rl.Vector2{0, 0},
		0,
		rl.WHITE,
	)
	water_end(&app.water)
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
	if rl.IsKeyDown(.Q) || rl.IsMouseButtonDown(.RIGHT) do held += {.Throw}

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
app_draw_glow :: proc(app: ^App, wx, wy: f32, halo, blaze: i32, peak, glow: f32, wide_color, core_color: rl.Color) {
	scale := f32(app.zoom) / f32(app.step)
	x := (wx - f32(app.cam_x)) * scale
	y := (wy - f32(app.cam_y)) * scale

	margin := f32(halo) * scale
	if x < -margin || y < -margin || x > WINDOW_W + margin || y > WINDOW_H + margin do return

	at := rl.Vector2{x, y}
	wide := f32(halo) * scale * glow
	rl.DrawCircleV(at, wide, rl.Fade(wide_color, 0.16 * peak * glow))
	rl.DrawCircleV(at, wide * 0.55, rl.Fade(wide_color, 0.32 * peak * glow))
	rl.DrawCircleV(at, max(f32(blaze + 1) * scale * glow, 1.5), rl.Fade(core_color, glow))
}

@(private = "file")
app_draw_crystals :: proc(app: ^App) {
	if !app_lighting(app) do return

	clock := rl.GetTime()
	for i in 0 ..< int(app.light.count) {
		c := app.light.crystals[i]
		app_draw_glow(
			app, c.x, c.y,
			LIGHT_CRYSTAL_HALO, LIGHT_CRYSTAL_BLAZE, LIGHT_CRYSTAL_PEAK,
			light_crystal_glow(c, clock),
			LIGHT_GLOW, LIGHT_CORE,
		)
	}
}

@(private = "file")
app_draw_fireflies :: proc(app: ^App) {
	if !app_lighting(app) do return

	clock := rl.GetTime()
	for i in 0 ..< int(app.flies.count) {
		f := app.flies.flies[i]
		app_draw_glow(
			app, f.x, f.y,
			FIREFLY_HALO, FIREFLY_BLAZE, FIREFLY_PEAK,
			firefly_glow(f, clock),
			FIREFLY_GLOW, FIREFLY_CORE,
		)
	}
}

@(private = "file")
app_draw_pots :: proc(app: ^App) {
	if !app_lighting(app) do return

	scale := f32(app.zoom) / f32(app.step)
	for i in 0 ..< int(app.pots.count) {
		p := app.pots.pots[i]
		if !p.live do continue

		x := (p.x - f32(app.cam_x)) * scale
		y := (p.y - f32(app.cam_y)) * scale
		r := f32(POT_R) * scale

		rl.DrawCircleV(rl.Vector2{x, y}, r, POT_BODY)
		app_draw_glow(
			app, p.x, p.y-f32(POT_R),
			POT_FUSE_HALO, POT_FUSE_BLAZE, POT_FUSE_PEAK, 1,
			pot_fuse_glow(app.world.materials), LIGHT_CORE,
		)
	}
}

// Every explosion the world remembers, whatever set it off.
@(private = "file")
app_draw_bangs :: proc(app: ^App) {
	if !app_lighting(app) do return

	table := app.world.materials
	sb := &app.sandbox
	for b in sb.bangs.bangs {
		if b.life <= 0 do continue
		glow := f32(bang_power(table, b)) / 255
		app_draw_glow(
			app, f32(sb.origin_x + b.x), f32(sb.origin_y + b.y),
			BANG_HALO, BANG_BLAZE, BANG_PEAK, glow, BANG_GLOW, BANG_CORE,
		)
	}
}

@(private = "file")
app_draw_orb :: proc(app: ^App) {
	if !app_lighting(app) do return

	x, y := light_orb_at(app.player)
	app_draw_glow(app, x, y, LIGHT_ORB_HALO, LIGHT_ORB_BLAZE, LIGHT_ORB_PEAK, 1, LIGHT_GLOW, LIGHT_CORE)
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
	app_draw_orb(app)
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

	rl.DrawText("A D walk   SHIFT run   SPACE/W/UP jump, hold to fly   E/click dig where you point   Q/right-click throw a pot   wheel zoom   TAB world editor", 12, 100, 16, rl.GRAY)
}

@(test)
test_the_window_takes_a_shot_of_itself_only_when_it_is_asked_to :: proc(t: ^testing.T) {
	idle := read_window_shot([]string{})
	testing.expect(t, !idle.on, "with no arguments the window must open and stay open")

	asked := read_window_shot([]string{"shot=shots/water.png", "frames=140", "walk=-40"})
	testing.expect(t, asked.on, "shot= must turn the window shot on")
	testing.expectf(t, asked.path == "shots/water.png", "the path must be read whole, got %q", asked.path)
	testing.expectf(t, asked.frames == 140, "frames must be read, got %d", asked.frames)
	testing.expectf(t, asked.walk == -40, "a negative walk must walk him left, got %d", asked.walk)

	plain := read_window_shot([]string{"shot=shots/window.png"})
	testing.expectf(
		t, plain.frames == WINDOW_SHOT_FRAMES,
		"a shot with no frame count must draw WINDOW_SHOT_FRAMES first, got %d", plain.frames,
	)
	testing.expect(t, plain.walk == 0, "and must leave him where he spawned")

	junk := read_window_shot([]string{"shot=a.png", "frames=soon", "walk=", "nonsense"})
	testing.expectf(
		t, junk.frames == WINDOW_SHOT_FRAMES && junk.walk == 0,
		"a value that is not a number must leave the default standing, got frames=%d walk=%d",
		junk.frames, junk.walk,
	)
}

@(test)
test_a_throw_argument_holds_the_button_for_one_tick_then_runs_the_ticks_it_names :: proc(t: ^testing.T) {
	plain := read_window_shot([]string{"shot=shots/throw.png"})
	testing.expect(t, !plain.throw, "with no throw argument the window must not throw")

	asked := read_window_shot([]string{"shot=shots/throw.png", "throw=90", "ticks=10"})
	testing.expect(t, asked.throw, "throw= must turn the throw on")
	testing.expectf(t, asked.aim == PLAYER_AIM_DOWN, "throw=90 must read as aim down, got %d", asked.aim)
	testing.expectf(t, asked.ticks == 10, "ticks must be read, got %d", asked.ticks)
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
