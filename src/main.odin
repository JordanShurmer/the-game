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

	shaders: Material_Shaders,
	lux:     []u8,
	sky:     []u8,   // how much of `lux` is the day, so a shader can tell them apart

	// light_shade of every material at every lux, so the shade loop is
	// one lookup a pixel. See app_shade.
	shade_lut:     []rl.Color,
	shade_corners: []u32,
	sky_corners:   []u32, // the day's own row of corners, beside shade_corners

	look:  Look,
	clock: f32,

	prof_hud:  bool,
	prof_view: Prof,

	sprite:         Sprite_Sheet,
	sprite_texture: rl.Texture2D,

	drudge_sprite:         Sprite_Sheet,
	drudge_sprite_texture: rl.Texture2D,

	color_lut: [256]rl.Color,

	dirty:   bool,
	hud_off: bool, // a reel films the game, not the debug readout
}

WINDOW_SHOT_FRAMES :: 90

Window_Shot :: struct {
	path:    string,
	frames:  int,
	walk:    int,
	throw:   bool,
	aim:     u8,
	ticks:   int,
	look:    string,
	script:  string,
	record:  string,
	seed:    Maybe(u64),
	on:      bool,
	profile: bool,
}

BACKGROUND :: rl.Color{18, 20, 26, 255}

BEAM_GLOW :: rl.Color{110, 210, 255, 255}
BEAM_CORE :: rl.Color{236, 250, 255, 255}

main :: proc() {
	shot, args_ok := read_window_shot(os.args[1:])
	if !args_ok {
		fmt.eprintln(GAME_USAGE)
		os.exit(1)
	}

	app: App
	if !app_load_data(&app, shot.seed) {
		os.exit(1)
	}
	defer app_unload_data(&app)

	rl.InitWindow(WINDOW_W, WINDOW_H, "The Game - biome generation")
	defer rl.CloseWindow()
	rl.SetTargetFPS(60)

	app_init_view(&app)
	defer app_destroy_view(&app)

	if shot.look != "" && !app_look_at(&app, shot.look) {
		fmt.eprintfln("no material is named %s, so there is nothing to look at", shot.look)
		os.exit(1)
	}

	if shot.on && !app.look.on do app_walk(&app, shot.walk)
	if shot.on && shot.throw do app_throw(&app, shot.aim, shot.ticks)
	if shot.on && !shot.throw do app_settle(&app, shot.ticks)

	reel: Reel
	if shot.script != "" {
		loaded, reel_ok := reel_load(shot.script)
		if !reel_ok {
			fmt.eprintfln("the script %s could not be read", shot.script)
			os.exit(1)
		}
		reel = loaded
		reel.dir = shot.record
		if reel.dir != "" do os.make_directory(reel.dir)
		app.hud_off = true
	}

	frames := 0
	for !rl.WindowShouldClose() {
		// A reel must come out the same twice, so its clock is the
		// frame count and not the wall.
		app.clock = app.look.on || reel.on ? f32(frames) / 60 : f32(rl.GetTime())
		if !shot.on && !reel.on do app_handle_input(&app)

		filming := false
		if reel.on && !reel_done(reel) {
			filming = reel_step(&reel, &app)
			app_follow_player(&app)
		}

		playing := !app.editor.open && !app.tile_edit.open
		if app.dirty || (playing && app.follow_player) {
			app_regenerate(&app)
			app.dirty = false
		}

		w, h := app_view_cells(&app)

		draw := prof_begin()
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
		app_draw_materials(&app, w, h)
		if !app.look.on {
			// Bodies first, then the wizard with the front of the crop
			// over him, then every glow that is only light: a halo is
			// the light of the world, and the light of the world sits
			// over the crop, or the front pass rubs a hole in it the
			// exact shape of his frame.
			app_draw_water(&app, w, h)
			app_draw_drudges(&app)
			app_draw_pots(&app, &app.pots)
			app_draw_pots(&app, &app.drudge_pots)
			app_draw_player(&app)
			app_draw_crystals(&app)
			app_draw_fireflies(&app)
			app_draw_bangs(&app)
			app_draw_sparks(&app)
			app_draw_orb(&app)
			app_draw_beam(&app)
			if !app.hud_off do draw_hud(&app)
			draw_prof(&app)
			editor_draw(&app)
			tile_editor_draw(&app)
		}
		rl.EndDrawing()
		prof_end(.Draw, draw)
		prof.frames += 1

		// The overlay reads a snapshot a second old, so the numbers hold
		// still long enough to read. A shot run keeps the whole record
		// instead and prints it once at the end.
		if !shot.on && prof.frames >= 60 {
			app.prof_view = prof
			prof_reset()
		}

		frames += 1

		if reel.on {
			if filming {
				if reel.dir != "" && reel.shown % REEL_EVERY == 0 {
					frame_path := fmt.tprintf("%s/frame_%05d.png", reel.dir, reel.wrote)
					rl.TakeScreenshot(strings.clone_to_cstring(frame_path, context.temp_allocator))
					reel.wrote += 1
				}
				reel.shown += 1
			}
			if reel_done(reel) {
				// Where he ended is how a route is tuned: run the reel,
				// read the landing, move the digging a few cells.
				fmt.printfln(
					"%s: %d frames from %d segments, wizard at %.0f,%.0f",
					reel.dir != "" ? reel.dir : "(unrecorded)",
					reel.wrote, len(reel.segments), app.player.x, app.player.y,
				)
				free_all(context.temp_allocator)
				break
			}
		}

		if shot.on && frames >= shot.frames {
			rl.TakeScreenshot(strings.clone_to_cstring(shot.path, context.temp_allocator))
			// The file is the result of the run, so it is named the
			// same way bin/shot names the one it draws.
			fmt.printfln(
				"%s: %dx%d pixels, after %d frames",
				shot.path, WINDOW_W, WINDOW_H, frames,
			)
			if shot.profile {
				fmt.eprintln(prof_report(prof, context.temp_allocator))
			}
			free_all(context.temp_allocator)
			break
		}

		free_all(context.temp_allocator)
	}
}

// F3: what every phase of the tick and the frame costs, averaged over
// the last second. See src/prof.odin.
draw_prof :: proc(app: ^App) {
	if !app.prof_hud do return

	keep := prof
	prof = app.prof_view
	report := prof_report(prof, context.temp_allocator)
	prof = keep

	lines := strings.split_lines(report, context.temp_allocator)
	y := i32(140)
	rl.DrawRectangle(0, y - 6, 340, i32(len(lines)) * 20 + 10, rl.Fade(rl.BLACK, 0.55))
	for line in lines {
		if line == "" do continue
		rl.DrawText(strings.clone_to_cstring(line, context.temp_allocator), 12, y, 18, rl.RAYWHITE)
		y += 20
	}
}

GAME_USAGE :: `usage: the-game [key=value ...]

Played with no arguments. The keys below drive it from a script
instead, which is how the shots and the reel are made.

  shot=PATH     write a PNG of the window and stop
  frames=N      how many frames to draw first
  walk=N        walk the wizard N ticks, left if negative
  throw=DEG     throw at this bearing
  ticks=N       settle the sandbox N ticks
  look=NAME     open the material viewer on a material
  script=PATH   play a reel script
  record=DIR    write every reel frame into DIR
  profile=1     print the phase table on exit
  seed=N        which world to open; seed=0x1AB is the Laboratory
  debug=0..3    0 the result, 1 the steps, 2 the detail, 3 everything

Run it from the repository root: the data paths are relative to it.`

read_window_shot :: proc(args: []string) -> (shot: Window_Shot, ok: bool) {
	shot.frames = WINDOW_SHOT_FRAMES

	// Every value that should be a number is read the same way, so a
	// word where a number belongs stops the run whichever key it was
	// given to, rather than leaving a default standing and drawing
	// something nobody asked for.
	number :: proc(key, value: string) -> (int, bool) {
		n, parsed := strconv.parse_int(value)
		if !parsed {
			fmt.eprintfln("%s wants a whole number, and %q is not one", key, value)
			return 0, false
		}
		return n, true
	}

	for arg in args {
		split := strings.index_byte(arg, '=')
		if split < 0 {
			fmt.eprintfln("arguments are key=value, and %q is not", arg)
			return shot, false
		}
		key := arg[:split]
		value := arg[split + 1:]

		n: int
		read := true
		switch key {
		case "debug":
			n, read = number(key, value)
			if read do noise_set(n)
		case "shot":
			shot.path = value
			shot.on = true
		case "frames":
			n, read = number(key, value)
			shot.frames = max(n, 1)
		case "walk":
			shot.walk, read = number(key, value)
		case "throw":
			n, read = number(key, value)
			shot.throw = read
			shot.aim = u8(i32(math.round(f32(n) / 360 * 256)) & 255)
		case "ticks":
			n, read = number(key, value)
			shot.ticks = max(n, 0)
		case "look":
			shot.look = value
		case "script":
			shot.script = value
		case "record":
			shot.record = value
		case "profile":
			n, read = number(key, value)
			shot.profile = n != 0
		case "seed":
			// A seed is a world, and hexadecimal is a seed too, which
			// is how seed=0x1AB opens the Laboratory. It is not read
			// by `number` above because a world is a u64 where these
			// are ints, and because a number too big for one must be
			// refused rather than wrapped. See parse_seed in
			// src/laboratory.odin.
			seed, seed_ok := parse_seed(value)
			read = seed_ok
			if read {
				shot.seed = seed
			} else {
				fmt.eprintfln("seed wants a whole number that fits in 64 bits, and %q is not one", value)
			}
		case:
			fmt.eprintfln("there is no argument %q", key)
			return shot, false
		}
		if !read do return shot, false
	}
	return shot, true
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

// Stand still and let the world run. `walk` moves him and steps the
// sandbox with him, which is how a shot of the trail is taken; this is
// for a shot of matter that moves on its own -- water running out of a
// sluice, a fire walking a hedge -- where he is a bystander and moving
// him would only put him in the way.
@(private = "file")
app_settle :: proc(app: ^App, ticks: int) {
	for _ in 0 ..< ticks {
		sim_step_player(&app.sim, {}, false)
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

app_load_data :: proc(app: ^App, seed: Maybe(u64) = nil) -> bool {
	if err := sim_load(&app.sim, seed = seed); err != .None do return false

	sim_play_begin(&app.sim)

	for m, i in app.world.materials.materials {
		app.color_lut[i] = blend_over(rl_from_argb(m.color), BACKGROUND)
	}

	app.shade_lut = make([]rl.Color, len(app.world.materials.materials) * 256)
	for m in 0 ..< len(app.world.materials.materials) {
		for lux in 0 ..< 256 {
			app.shade_lut[m * 256 + lux] = light_shade(app.color_lut[m], u8(lux))
		}
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
	delete(app.shade_lut)
	sim_unload(&app.sim)
}

app_init_view :: proc(app: ^App) {
	app.cells = make([]Cell, WINDOW_W * WINDOW_H)
	app.pixels = make([]rl.Color, WINDOW_W * WINDOW_H)
	app.lux = make([]u8, WINDOW_W * WINDOW_H)
	app.sky = make([]u8, WINDOW_W * WINDOW_H)
	app.water_run = make([]u8, WINDOW_W)
	app.shade_corners = make([]u32, WINDOW_W / LIGHT_CELL + 3)
	app.sky_corners = make([]u32, WINDOW_W / LIGHT_CELL + 3)

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

	app.shaders = material_shaders_load(app.world.materials, WINDOW_W, WINDOW_H)
	if !app.shaders.on {
		fmt.eprintfln("%s brought no shader: every material is drawn flat", MATERIAL_SHADER_DIR)
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

	drudge_sheet, drudge_result := load_drudge_sprite_sheet()
	if drudge_result.err != .None {
		fmt.eprintfln("the drudge sprite sheet could not load: %v", drudge_result.err)
	}
	app.drudge_sprite = drudge_sheet

	if drudge_sheet.pixels != nil {
		img := rl.Image {
			data    = raw_data(drudge_sheet.pixels),
			width   = drudge_sheet.width,
			height  = drudge_sheet.height,
			mipmaps = 1,
			format  = .UNCOMPRESSED_R8G8B8A8,
		}
		app.drudge_sprite_texture = rl.LoadTextureFromImage(img)
		rl.SetTextureFilter(app.drudge_sprite_texture, .POINT)
	}
}

app_destroy_view :: proc(app: ^App) {
	rl.UnloadTexture(app.drudge_sprite_texture)
	destroy_sprite_sheet(app.drudge_sprite)
	rl.UnloadTexture(app.sprite_texture)
	destroy_sprite_sheet(app.sprite)
	material_shaders_unload(&app.shaders)
	water_unload(&app.water)
	rl.UnloadTexture(app.texture)
	delete(app.cells)
	delete(app.pixels)
	delete(app.lux)
	delete(app.sky)
	delete(app.water_run)
	delete(app.shade_corners)
	delete(app.sky_corners)
}

app_view_cells :: proc(app: ^App) -> (w, h: i32) {
	return WINDOW_W / app.zoom, WINDOW_H / app.zoom
}

app_regenerate :: proc(app: ^App) {
	w, h := app_view_cells(app)
	if app.look.on {
		app_regenerate_look(app, w, h)
		return
	}

	view := World_View {
		x    = app.cam_x,
		y    = app.cam_y,
		w    = w,
		h    = h,
		step = app.step,
	}
	// When the sandbox holds every cell the view samples, the copy below
	// overwrites everything generate would write, so generate has nothing
	// to say and is skipped.
	at := prof_begin()
	if !(app.follow_player && app_sandbox_covers(app, view)) {
		generate(app.world, view, app.cells)
	}
	prof_end(.Generate, at)

	if app.follow_player {
		at = prof_begin()
		app_draw_sandbox(app, view)
		prof_end(.Sandbox_Copy, at)
	}

	at = prof_begin()
	if app_lighting(app) {
		app_shade(app, view)
	} else {
		count := int(w) * int(h)
		for i in 0 ..< count {
			app.pixels[i] = app.color_lut[app.cells[i]]
		}
	}
	prof_end(.Shade, at)

	at = prof_begin()
	rl.UpdateTextureRec(app.texture, rl.Rectangle{0, 0, f32(w), f32(h)}, raw_data(app.pixels))
	prof_end(.Upload, at)

	if app_lighting(app) {
		at = prof_begin()
		water_mark(&app.water, app.cells, w, h, app.water_run)
		prof_end(.Water_Mark, at)

		at = prof_begin()
		material_shaders_mark(&app.shaders, app.cells, app.lux, w, h, app.sky)
		prof_end(.Shader_Mark, at)
	}
}

app_lighting :: proc(app: ^App) -> bool {
	return app.look.on || (app.follow_player && !app.editor.open && !app.tile_edit.open)
}

// Point the whole view at one material, on the bench. See src/look.odin.
app_look_at :: proc(app: ^App, name: string) -> bool {
	idx, found := find_material_index(app.world.materials, name)
	if !found do return false

	app.look = Look {
		cell = Cell(idx),
		on   = true,
	}
	app.step = 1
	app.zoom = WORLD_VIEW_MAX_ZOOM
	app.cam_x = 0
	app.cam_y = 0
	app.dirty = true
	return true
}

@(private = "file")
app_regenerate_look :: proc(app: ^App, w, h: i32) {
	look_fill(app.look, app.cells, app.lux, w, h)

	count := int(w) * int(h)
	for i in 0 ..< count {
		app.pixels[i] = app.shade_lut[int(app.cells[i]) * 256 + int(app.lux[i])]
	}
	rl.UpdateTextureRec(app.texture, rl.Rectangle{0, 0, f32(w), f32(h)}, raw_data(app.pixels))
	material_shaders_mark(&app.shaders, app.cells, app.lux, w, h)
}

@(private = "file")
app_shade :: proc(app: ^App, view: World_View) {
	if view.step == 1 && app.light.stat != nil {
		app_shade_fine(app, view)
		return
	}
	for ty in i32(0) ..< view.h {
		wy := view.y + ty * view.step
		row := app.cells[int(ty) * int(view.w):][:view.w]
		out := app.pixels[int(ty) * int(view.w):][:view.w]

		lit := app.lux[int(ty) * int(view.w):][:view.w]
		day := app.sky[int(ty) * int(view.w):][:view.w]

		for tx in i32(0) ..< view.w {
			wx := view.x + tx * view.step
			lux := light_lux(&app.light, wx, wy)
			sky := light_sky_lux(&app.light, wx, wy)
			lit[tx] = lux
			day[tx] = sky
			out[tx] = sky == 0 ? app.shade_lut[int(row[tx]) * 256 + int(lux)] : light_shade(app.color_lut[row[tx]], lux, sky)
		}
	}
}

// At step 1 the light grid holds still for LIGHT_CELL pixels at a time,
// so the corners are fetched once a square and blended down the row,
// instead of light_lux fetching all four again for every pixel. The
// blend is the same sum light_lux computes, so the two paths agree to
// the bit; test_the_fine_shade_matches_light_lux holds them together.
// The day rides the same machinery: a second corner row from the day
// grid, so a pixel knows how much of its light is the sky's without a
// second interpolation path existing anywhere.
@(private = "file")
app_shade_fine :: proc(app: ^App, view: World_View) {
	l := &app.light

	fx0 := view.x - l.origin_x - LIGHT_CELL / 2
	lx0 := floor_div(fx0, LIGHT_CELL)
	tx0 := u32(fx0 - lx0 * LIGHT_CELL)
	corners := int(floor_div(fx0 + view.w - 1, LIGHT_CELL) - lx0) + 2

	day_corner :: #force_inline proc(l: ^Light, lx, ly: i32) -> u32 {
		if lx < 0 || ly < 0 || lx >= LIGHT_W || ly >= LIGHT_H do return 0
		return u32(l.day[int(ly) * LIGHT_W + int(lx)])
	}

	for ty in i32(0) ..< view.h {
		wy := view.y + ty
		fy := wy - l.origin_y - LIGHT_CELL / 2
		ly := floor_div(fy, LIGHT_CELL)
		wy_t := u32(fy - ly * LIGHT_CELL)

		for k in 0 ..< corners {
			cx := lx0 + i32(k)
			top := light_corner(l, cx, ly)
			bottom := light_corner(l, cx, ly + 1)
			app.shade_corners[k] = top * (LIGHT_CELL - wy_t) + bottom * wy_t

			sky_top := day_corner(l, cx, ly)
			sky_bottom := day_corner(l, cx, ly + 1)
			app.sky_corners[k] = sky_top * (LIGHT_CELL - wy_t) + sky_bottom * wy_t
		}

		row := app.cells[int(ty) * int(view.w):][:view.w]
		out := app.pixels[int(ty) * int(view.w):][:view.w]
		lit := app.lux[int(ty) * int(view.w):][:view.w]
		day := app.sky[int(ty) * int(view.w):][:view.w]

		k := 0
		t := tx0
		for tx in i32(0) ..< view.w {
			left := app.shade_corners[k]
			right := app.shade_corners[k + 1]
			lux := u8((left * (LIGHT_CELL - t) + right * t) / (LIGHT_CELL * LIGHT_CELL))
			sky := u8((app.sky_corners[k] * (LIGHT_CELL - t) + app.sky_corners[k + 1] * t) / (LIGHT_CELL * LIGHT_CELL))
			lit[tx] = lux
			day[tx] = sky
			out[tx] = sky == 0 ? app.shade_lut[int(row[tx]) * 256 + int(lux)] : light_shade(app.color_lut[row[tx]], lux, sky)

			t += 1
			if t == LIGHT_CELL {
				t = 0
				k += 1
			}
		}
	}
}

// Every material that brings a shader paints over its own cells, before
// the water lays its surface over the top of them.
@(private = "file")
app_draw_materials :: proc(app: ^App, w, h: i32) {
	if !app_lighting(app) do return

	material_shaders_draw(
		&app.shaders,
		app.texture,
		rl.Rectangle{0, 0, f32(w), f32(h)},
		rl.Rectangle{0, 0, WINDOW_W, WINDOW_H},
		{WINDOW_W, WINDOW_H},
		{f32(app.cam_x), f32(app.cam_y)},
		f32(app.step),
		app.clock,
	)
}

@(private = "file")
app_draw_water :: proc(app: ^App, w, h: i32) {
	if !app_lighting(app) do return
	if !app.water.on do return
	if app.water.box.min_x > app.water.box.max_x do return // no water in view

	sub_src, sub_dst := material_shader_rects(
		app.water.box,
		rl.Rectangle{0, 0, f32(w), f32(h)},
		rl.Rectangle{0, 0, WINDOW_W, WINDOW_H},
	)

	water_begin(
		&app.water,
		{WINDOW_W, WINDOW_H},
		{f32(app.cam_x), f32(app.cam_y)},
		f32(app.step),
		app.clock,
	)
	rl.DrawTexturePro(app.texture, sub_src, sub_dst, rl.Vector2{0, 0}, 0, rl.WHITE)
	water_end(&app.water)
}

@(private = "file")
app_sandbox_covers :: proc(app: ^App, view: World_View) -> bool {
	sb := &app.sandbox
	return view.x >= sb.origin_x && view.y >= sb.origin_y &&
		view.x + (view.w - 1) * view.step < sb.origin_x + sb.width &&
		view.y + (view.h - 1) * view.step < sb.origin_y + sb.height
}

// The first tx whose sample lands at or past `edge`, so the row loops
// below run only over the sandbox and test no bounds per cell.
@(private = "file")
view_first_at :: proc(view_at, edge, step: i32) -> i32 {
	return floor_div(edge - view_at + step - 1, step)
}

@(private = "file")
app_draw_sandbox :: proc(app: ^App, view: World_View) {
	sb := &app.sandbox

	tx0 := clamp(view_first_at(view.x, sb.origin_x, view.step), 0, view.w)
	tx1 := clamp(view_first_at(view.x, sb.origin_x + sb.width, view.step), tx0, view.w)
	ty0 := clamp(view_first_at(view.y, sb.origin_y, view.step), 0, view.h)
	ty1 := clamp(view_first_at(view.y, sb.origin_y + sb.height, view.step), ty0, view.h)

	for ty in ty0 ..< ty1 {
		sy := view.y + ty * view.step - sb.origin_y
		row := app.cells[int(ty) * int(view.w):][:view.w]
		from := sb.cells[int(sy) * int(sb.width):][:sb.width]

		sx := view.x + tx0 * view.step - sb.origin_x
		if view.step == 1 {
			copy(row[tx0:tx1], from[sx:])
			continue
		}
		for tx in tx0 ..< tx1 {
			row[tx] = from[sx]
			sx += view.step
		}
	}
}

app_handle_input :: proc(app: ^App) {
	if app.tile_edit.open {
		tile_editor_handle_input(app)
		return
	}

	if rl.IsKeyPressed(.F3) do app.prof_hud = !app.prof_hud

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

	// A blaze below zero says the light has no heart to draw: it is a
	// patch of glow soaked into the place, so the middle is one more
	// soft ring and never a point. The shot path keeps the same rule.
	if blaze < 0 {
		rl.DrawCircleV(at, wide * 0.30, rl.Fade(wide_color, 0.30 * peak * glow))
		return
	}
	rl.DrawCircleV(at, max(f32(blaze + 1) * scale * glow, 1.5), rl.Fade(core_color, glow))
}

// A crystal is a tiny rupee of light: a slim six-sided gem, amber at
// the rim and white at the heart, inside a wide faint halo. The gem is
// the thing you can see the light coming from, and it is kept far
// smaller than the light it gives.
@(private = "file")
app_draw_rupee :: proc(at: rl.Vector2, w, h, waist: f32, color: rl.Color) {
	rl.DrawRectangleRec(rl.Rectangle{at.x - w, at.y - waist, 2 * w, 2 * waist}, color)
	// Vertex order keeps each triangle counter-clockwise on a screen
	// whose y runs down, the way app_beam_quad orders its strip.
	rl.DrawTriangle(
		rl.Vector2{at.x, at.y - h},
		rl.Vector2{at.x - w, at.y - waist},
		rl.Vector2{at.x + w, at.y - waist},
		color,
	)
	rl.DrawTriangle(
		rl.Vector2{at.x, at.y + h},
		rl.Vector2{at.x + w, at.y + waist},
		rl.Vector2{at.x - w, at.y + waist},
		color,
	)
}

@(private = "file")
app_draw_crystals :: proc(app: ^App) {
	if !app_lighting(app) do return

	scale := f32(app.zoom) / f32(app.step)
	clock := rl.GetTime()
	for i in 0 ..< int(app.light.count) {
		c := app.light.crystals[i]
		glow := light_crystal_glow(c, clock)
		app_draw_glow(
			app, c.x, c.y,
			LIGHT_CRYSTAL_HALO, LIGHT_CRYSTAL_BLAZE, LIGHT_CRYSTAL_PEAK,
			glow,
			LIGHT_GLOW, LIGHT_CORE,
		)

		x := (c.x - f32(app.cam_x)) * scale
		y := (c.y - f32(app.cam_y)) * scale
		if x < -2 * scale || y < -2 * scale || x > WINDOW_W + 2 * scale || y > WINDOW_H + 2 * scale do continue

		at := rl.Vector2{x, y}
		app_draw_rupee(at, 0.9 * scale, 1.7 * scale, 0.7 * scale, rl.Fade(LIGHT_GLOW, 0.90))
		app_draw_rupee(at, 0.45 * scale, 0.9 * scale, 0.35 * scale, rl.Fade(LIGHT_CORE, 0.55 + 0.45 * glow))
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

// The drudge sheet drawn exactly the way `app_draw_player` draws the
// wizard's own: pick a row from his state, a column from his own
// animation clock, and blit the frame, mirrored to his facing. See
// docs/drudge.md, "Looking at him".
@(private = "file")
app_draw_drudges :: proc(app: ^App) {
	if app.drudge_sprite.pixels == nil do return

	scale := f32(app.zoom) / f32(app.step)

	for i in 0 ..< int(app.drudges.count) {
		d := app.drudges.drudges[i]
		facing := drudge_facing(d, app.player)
		motion := drudge_motion(d)
		column := drudge_sprite_frame(motion, d.anim)

		src := rl.Rectangle {
			x      = f32(column * DRUDGE_SPRITE_FRAME_W),
			y      = f32(int(motion) * DRUDGE_SPRITE_FRAME_H),
			width  = f32(DRUDGE_SPRITE_FRAME_W) * f32(facing),
			height = f32(DRUDGE_SPRITE_FRAME_H),
		}

		origin_x, origin_y := drudge_sprite_frame_origin(d)
		dst := rl.Rectangle {
			x      = f32(origin_x - app.cam_x) * scale,
			y      = f32(origin_y - app.cam_y) * scale,
			width  = f32(DRUDGE_SPRITE_FRAME_W) * scale,
			height = f32(DRUDGE_SPRITE_FRAME_H) * scale,
		}

		rl.DrawTexturePro(app.drudge_sprite_texture, src, dst, rl.Vector2{0, 0}, 0, rl.WHITE)

		if app_lighting(app) {
			lx, ly := drudge_lamp_at(d, facing)
			app_draw_glow(
				app, lx, ly,
				DRUDGE_LAMP_HALO, DRUDGE_LAMP_BLAZE, DRUDGE_LAMP_PEAK, 1,
				drudge_lamp_glow(app.world.materials), LIGHT_CORE,
			)
		}
	}
}

@(private = "file")
app_draw_pots :: proc(app: ^App, bag: ^Pot_Bag) {
	if !app_lighting(app) do return

	scale := f32(app.zoom) / f32(app.step)
	for i in 0 ..< int(bag.count) {
		p := bag.pots[i]
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

// Every sparkle the mix throws off, whatever reaction made it.
@(private = "file")
app_draw_sparks :: proc(app: ^App) {
	if !app_lighting(app) do return

	table := app.world.materials
	sb := &app.sandbox
	for sp in sb.sparks.sparks {
		if sp.life <= 0 do continue
		glow := f32(spark_power(table, sp)) / 255
		app_draw_glow(
			app, f32(sb.origin_x + sp.x), f32(sb.origin_y + sp.y),
			SPARKLE_HALO, SPARKLE_BLAZE, SPARKLE_PEAK, glow, SPARKLE_GLOW, SPARKLE_CORE,
		)
	}
}

@(private = "file")
app_draw_orb :: proc(app: ^App) {
	if !app_lighting(app) do return
	// He puts it out in the daylight, so it must not be drawn there.
	if !app.light.orb_lit do return

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
	app_draw_brush_front(app, origin_x, origin_y)
}

// The front share of the standing crop, painted back over his sprite,
// so a walk through a wheatfield puts stalks before him and stalks
// behind. Everything that is only light -- the orb, the beam, every
// halo -- draws after it, because the light of the world sits over
// the crop.
@(private = "file")
app_draw_brush_front :: proc(app: ^App, origin_x, origin_y: i32) {
	if !app_lighting(app) do return

	w, h := app_view_cells(app)
	frame := Sandbox_Rect {
		min_x = floor_div(origin_x - app.cam_x, app.step),
		min_y = floor_div(origin_y - app.cam_y, app.step),
		max_x = floor_div(origin_x + SPRITE_FRAME_W - 1 - app.cam_x, app.step),
		max_y = floor_div(origin_y + SPRITE_FRAME_H - 1 - app.cam_y, app.step),
	}

	material_shaders_draw_front(
		&app.shaders,
		app.texture,
		rl.Rectangle{0, 0, f32(w), f32(h)},
		rl.Rectangle{0, 0, WINDOW_W, WINDOW_H},
		{WINDOW_W, WINDOW_H},
		{f32(app.cam_x), f32(app.cam_y)},
		f32(app.step),
		app.clock,
		frame,
	)
}

// A four-cornered ribbon of light, wide at one end and narrow at the
// other. The strip order (+w0, -w0, +w1, -w1) is what keeps raylib's
// winding happy whichever way the beam points.
@(private = "file")
app_beam_quad :: proc(from, to: rl.Vector2, w0, w1: f32, color: rl.Color) {
	d := rl.Vector2{to.x - from.x, to.y - from.y}
	length := math.sqrt(d.x * d.x + d.y * d.y)
	if length < 0.001 do return
	// This side of the perpendicular keeps every triangle of the strip
	// counter-clockwise on a screen whose y runs down; the other side
	// is back-facing whichever way the beam points, and raylib culls it.
	p := rl.Vector2{d.y / length, -d.x / length}

	quad := [4]rl.Vector2 {
		{from.x + p.x * w0, from.y + p.y * w0},
		{from.x - p.x * w0, from.y - p.y * w0},
		{to.x + p.x * w1, to.y + p.y * w1},
		{to.x - p.x * w1, to.y - p.y * w1},
	}
	rl.DrawTriangleStrip(raw_data(quad[:]), 4, color)
}

// The digging beam. It leaves the staff rather than his belly, it
// stops where the cut itself stops instead of shining through the
// world, it narrows as it goes, it wavers a little, and it is laid on
// additively, so it reads as light over the picture and not as chalk
// drawn across it. Where it lands on something too hard to cut, the
// impact glows.
@(private = "file")
app_draw_beam :: proc(app: ^App) {
	if app.editor.open || app.tile_edit.open do return

	p := app.player
	if !p.digging do return

	cx, cy := player_centre(p)
	dx, dy := player_aim_vector(p.aim)

	// Where the beam ends: sandbox_cut_reach, which is the same one
	// procedure the kerf itself measures by, so the picture and the
	// tool cannot disagree on where the cutting stops. On a hit the
	// beam runs one cell past the reach, onto the face it is burning
	// against.
	sb := &app.sandbox
	cut, hit := sandbox_cut_reach(
		sb, app.world.materials,
		cx - sb.origin_x, cy - sb.origin_y,
		dx, dy, PLAYER_DIG_RANGE, PLAYER_DIG_POWER,
	)
	reach := f32(cut)
	if hit do reach += 1

	scale := f32(app.zoom) / f32(app.step)
	ox, oy := light_orb_at(p)
	from := rl.Vector2{(ox - f32(app.cam_x)) * scale, (oy - f32(app.cam_y)) * scale}
	to := rl.Vector2 {
		(f32(cx) + dx * reach - f32(app.cam_x)) * scale,
		(f32(cy) + dy * reach - f32(app.cam_y)) * scale,
	}

	// Two beat frequencies, so the waver never settles into a pulse.
	flick := 0.85 + 0.10 * math.sin(app.clock * 34.0) + 0.05 * math.sin(app.clock * 9.1)

	rl.BeginBlendMode(.ADDITIVE)
	app_beam_quad(from, to, 3.2 * scale, 0.9 * scale, rl.Fade(BEAM_GLOW, 0.10 * flick))
	app_beam_quad(from, to, 1.6 * scale, 0.6 * scale, rl.Fade(BEAM_GLOW, 0.20 * flick))
	app_beam_quad(from, to, 0.55 * scale, 0.25 * scale, rl.Fade(BEAM_CORE, 0.85 * flick))
	if hit {
		rl.DrawCircleV(to, 2.2 * scale, rl.Fade(BEAM_GLOW, 0.35 * flick))
		rl.DrawCircleV(to, 1.1 * scale, rl.Fade(BEAM_CORE, 0.55 * flick))
	} else {
		rl.DrawCircleV(to, 1.2 * scale, rl.Fade(BEAM_GLOW, 0.18 * flick))
	}
	rl.EndBlendMode()
}

draw_hud :: proc(app: ^App) {
	if app.editor.open || app.tile_edit.open do return

	w, h := app_view_cells(app)
	cx := app.cam_x + (w / 2) * app.step
	cy := app.cam_y + (h / 2) * app.step
	id := world_biome_at(app.world, cx, cy)
	b := app.world.biomes.biomes[id]

	// Which world he is standing in, because a seed is a world and one
	// seed is a different one. See src/laboratory.odin.
	world := world_is_laboratory(app.world.biomes, app.world.seed) ? "Laboratory" : "world"

	rl.DrawRectangle(0, 0, 620, 130, rl.Fade(rl.BLACK, 0.55))
	rl.DrawText(
		fmt.ctprintf(
			"centre %d, %d   %d cell/texel   %dx zoom   %s seed %d",
			cx, cy, app.step, app.zoom, world, app.world.seed,
		),
		12, 10, 18, rl.RAYWHITE,
	)
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

// The fast shade and the plain one must be the same picture. The fine
// path blends corners once a square; light_lux fetches them per pixel;
// the sums are the same polynomial, and this holds them to it.
@(test)
test_the_fine_shade_matches_light_lux :: proc(t: ^testing.T) {
	app: App
	app.light = light_make(7)
	defer light_destroy(&app.light)
	app.light.origin_x = -SANDBOX_PLAY_SIZE
	app.light.origin_y = 0

	// A little landscape of light, off both grids, bright and faint.
	for i in 0 ..< LIGHT_SAMPLES {
		app.light.stat[i] = u8((i * 37) % 251)
		app.light.live[i] = u8((i * 101 + 13) % 249)
	}

	w, h := i32(64), i32(48)
	app.cells = make([]Cell, int(w) * int(h))
	app.pixels = make([]rl.Color, int(w) * int(h))
	app.lux = make([]u8, int(w) * int(h))
	app.sky = make([]u8, int(w) * int(h))
	app.shade_corners = make([]u32, WINDOW_W / LIGHT_CELL + 3)
	app.sky_corners = make([]u32, WINDOW_W / LIGHT_CELL + 3)
	app.shade_lut = make([]rl.Color, 256 * 256)
	defer {
		delete(app.cells)
		delete(app.pixels)
		delete(app.lux)
		delete(app.sky)
		delete(app.shade_corners)
		delete(app.sky_corners)
		delete(app.shade_lut)
	}
	for m in 0 ..< 256 {
		for lux in 0 ..< 256 {
			app.shade_lut[m * 256 + lux] = light_shade(app.color_lut[m], u8(lux))
		}
	}

	// A view that hangs off the light grid on two sides, so the edge
	// corners run through the out-of-grid path too.
	views := []World_View {
		{x = app.light.origin_x - 10, y = -9, w = w, h = h, step = 1},
		{x = app.light.origin_x + 200, y = 300, w = w, h = h, step = 1},
		{x = app.light.origin_x + SANDBOX_PLAY_SIZE - 30, y = SANDBOX_PLAY_SIZE - 20, w = w, h = h, step = 1},
	}
	for view in views {
		for i in 0 ..< len(app.cells) do app.cells[i] = Cell(i % 53)
		app_shade_fine(&app, view)

		for ty in i32(0) ..< h {
			for tx in i32(0) ..< w {
				want := light_lux(&app.light, view.x + tx, view.y + ty)
				got := app.lux[int(ty) * int(w) + int(tx)]
				ok := testing.expectf(
					t, got == want,
					"view %v pixel %d,%d: the fine shade says %d, light_lux says %d",
					view, tx, ty, got, want,
				)
				if !ok do return
			}
		}
	}
}

// The clipped sandbox copy must paint exactly the cells the bounded
// per-cell loop painted, for views hanging off every side of it.
@(test)
test_the_sandbox_copy_matches_the_plain_loop :: proc(t: ^testing.T) {
	app: App
	sb, ok := sandbox_make(96, 80, 5)
	if !testing.expect(t, ok, "the sandbox must be created") do return
	defer sandbox_destroy(&sb)
	sb.origin_x = -37
	sb.origin_y = 23
	for i in 0 ..< len(sb.cells) do sb.cells[i] = Cell(i % 251)
	app.sandbox = sb

	w, h := i32(40), i32(30)
	app.cells = make([]Cell, int(w) * int(h))
	want := make([]Cell, int(w) * int(h))
	defer {
		delete(app.cells)
		delete(want)
	}

	views := []World_View {
		{x = -37, y = 23, w = w, h = h, step = 1},
		{x = -60, y = 0, w = w, h = h, step = 1},
		{x = 30, y = 80, w = w, h = h, step = 1},
		{x = -100, y = -10, w = w, h = h, step = 3},
		{x = -38, y = 22, w = w, h = h, step = 7},
		{x = 500, y = 500, w = w, h = h, step = 1},
	}
	for view in views {
		for i in 0 ..< len(app.cells) {
			app.cells[i] = 255
			want[i] = 255
		}
		for ty in i32(0) ..< view.h {
			wy := view.y + ty * view.step
			sy := wy - sb.origin_y
			if sy < 0 || sy >= sb.height do continue
			for tx in i32(0) ..< view.w {
				wx := view.x + tx * view.step
				sx := wx - sb.origin_x
				if sx < 0 || sx >= sb.width do continue
				want[int(ty) * int(view.w) + int(tx)] = sandbox_cell(&app.sandbox, sx, sy)
			}
		}

		app_draw_sandbox(&app, view)
		for i in 0 ..< len(want) {
			same := testing.expectf(
				t, app.cells[i] == want[i],
				"view %v cell %d: the clipped copy says %d, the plain loop says %d",
				view, i, app.cells[i], want[i],
			)
			if !same do return
		}
	}
	app.sandbox = {}
}

@(test)
test_the_window_takes_a_shot_of_itself_only_when_it_is_asked_to :: proc(t: ^testing.T) {
	idle, _ := read_window_shot([]string{})
	testing.expect(t, !idle.on, "with no arguments the window must open and stay open")

	asked, _ := read_window_shot([]string{"shot=shots/water.png", "frames=140", "walk=-40"})
	testing.expect(t, asked.on, "shot= must turn the window shot on")
	testing.expectf(t, asked.path == "shots/water.png", "the path must be read whole, got %q", asked.path)
	testing.expectf(t, asked.frames == 140, "frames must be read, got %d", asked.frames)
	testing.expectf(t, asked.walk == -40, "a negative walk must walk him left, got %d", asked.walk)

	plain, _ := read_window_shot([]string{"shot=shots/window.png"})
	testing.expectf(
		t, plain.frames == WINDOW_SHOT_FRAMES,
		"a shot with no frame count must draw WINDOW_SHOT_FRAMES first, got %d", plain.frames,
	)
	testing.expect(t, plain.walk == 0, "and must leave him where he spawned")

	// A wrong argument stops the run and shows the usage, rather than
	// drawing something nobody asked for. Each of these is one way to
	// get an argument wrong.
	wrong := [][]string{
		[]string{"shot=a.png", "frames=soon"},  // a value that is not a number
		[]string{"shot=a.png", "nonsense"},     // no key=value at all
		[]string{"shot=a.png", "verbose=1"},    // a key that does not exist
	}
	for junk in wrong {
		_, junk_ok := read_window_shot(junk)
		testing.expectf(t, !junk_ok, "%v must be refused, and the usage shown", junk)
	}
}

@(test)
test_a_throw_argument_holds_the_button_for_one_tick_then_runs_the_ticks_it_names :: proc(t: ^testing.T) {
	plain, _ := read_window_shot([]string{"shot=shots/throw.png"})
	testing.expect(t, !plain.throw, "with no throw argument the window must not throw")

	asked, _ := read_window_shot([]string{"shot=shots/throw.png", "throw=90", "ticks=10"})
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
