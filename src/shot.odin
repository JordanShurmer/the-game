package game

import "core:math"
import "core:os"
import "core:strings"
import "core:testing"
import rl "vendor:raylib"

SHOT_MAX_PIXELS :: 8192 * 8192

Shot :: struct {
	view:    World_View,
	scale:   i32,
	grid:    bool,
	player:  Maybe(Player),
	sprite:  Sprite_Sheet,
	sandbox: ^Sandbox,
	light:   ^Light,
	flies:        ^Firefly_Swarm,
	pots:         ^Pot_Bag,
	drudges:      ^Drudge_Bag,
	drudge_pots:  ^Pot_Bag,
	drudge_sprite: Sprite_Sheet,
}

SHOT_TILE_LINE :: rl.Color{255, 255, 255, 45}
SHOT_REGION_LINE :: rl.Color{255, 210, 90, 130}
world_shot :: proc(world: World, shot: Shot, path: string) -> bool {
	if shot.scale < 1 || shot.view.w <= 0 || shot.view.h <= 0 do return false

	width := shot.view.w * shot.scale
	height := shot.view.h * shot.scale
	if int(width) * int(height) > SHOT_MAX_PIXELS do return false

	cells := make([]Cell, int(shot.view.w) * int(shot.view.h))
	defer delete(cells)
	if shot.sandbox != nil {
		sb := shot.sandbox
		for ty in 0 ..< shot.view.h {
			wy := shot.view.y + ty * shot.view.step
			for tx in 0 ..< shot.view.w {
				wx := shot.view.x + tx * shot.view.step
				cells[int(ty)*int(shot.view.w) + int(tx)] = sandbox_cell(sb, wx - sb.origin_x, wy - sb.origin_y)
			}
		}
	} else {
		generate(world, shot.view, cells)
	}

	lut: [256]rl.Color
	for m, i in world.materials.materials {
		lut[i] = blend_over(rl_from_argb(m.color), BACKGROUND)
	}

	player, has_player := shot.player.?
	origin_x, origin_y: i32
	motion: Player_Motion
	column: int
	if has_player {
		origin_x, origin_y = sprite_frame_origin(player)
		motion = player_motion(player)
		column = sprite_frame(motion, player.anim)
	}

	pixels := make([]rl.Color, int(width) * int(height))
	defer delete(pixels)

	texels := make([]rl.Color, int(shot.view.w))
	defer delete(texels)

	for ty in 0 ..< shot.view.h {
		row := cells[int(ty) * int(shot.view.w):][:shot.view.w]
		wy := shot.view.y + ty * shot.view.step
		fy := wy - origin_y
		in_frame_row := has_player && fy >= 0 && fy < SPRITE_FRAME_H

		for tx in 0 ..< shot.view.w {
			wx := shot.view.x + tx * shot.view.step
			c := lut[row[tx]]

			if shot.light != nil {
				c = light_shade(c, light_lux(shot.light, wx, wy))
			}

			if in_frame_row {
				fx := wx - origin_x
				if fx >= 0 && fx < SPRITE_FRAME_W {
					sc := sprite_pixel(shot.sprite, motion, column, player.facing, fx, fy)
					if sc.a != 0 do c = blend_over(sc, c)
				}
			}
			texels[tx] = c
		}

		for sy in 0 ..< shot.scale {
			line := pixels[int(ty * shot.scale + sy) * int(width):][:width]
			for tx in 0 ..< shot.view.w {
				for sx in 0 ..< shot.scale {
					line[tx * shot.scale + sx] = texels[tx]
				}
			}
		}
	}

	if shot.light != nil {
		shot_draw_crystals(shot, pixels, width, height)
		shot_draw_fireflies(shot, pixels, width, height)
		shot_draw_drudges(world, shot, pixels, width, height)
		shot_draw_pots(world, shot, pixels, width, height, shot.pots)
		shot_draw_pots(world, shot, pixels, width, height, shot.drudge_pots)
		shot_draw_bangs(world, shot, pixels, width, height)
		shot_draw_sparks(world, shot, pixels, width, height)
		if has_player do shot_draw_orb(shot, pixels, width, height, player)
	}
	if shot.grid do shot_draw_grid(world, shot, pixels, width, height)

	img := rl.Image {
		data    = raw_data(pixels),
		width   = width,
		height  = height,
		mipmaps = 1,
		format  = .UNCOMPRESSED_R8G8B8A8,
	}

	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	defer delete(cpath, context.temp_allocator)
	return bool(rl.ExportImage(img, cpath))
}

Shot_Sandbox_Error :: enum u8 {
	None,
	Too_Large,
	Wrong_Step,
	Open_Failed,
}

shot_open_sandbox :: proc(s: ^Sim, view: World_View) -> Shot_Sandbox_Error {
	if view.step != 1 do return .Wrong_Step
	if view.w > SANDBOX_MAX_WIDTH || view.h > SANDBOX_MAX_HEIGHT do return .Too_Large
	if sim_open_sandbox(s, view.w, view.h, view.x, view.y, 1, 0) != .None do return .Open_Failed
	return .None
}

shot_biome_origin :: proc(world: World, biome: Biome_Id) -> (x: i32, y: i32, found: bool) {
	m := world.biome_map
	cpp := world.biomes.cells_per_pixel

	for py in i32(0) ..< m.height {
		for px in i32(0) ..< m.width {
			if biome_map_at(m, px, py) != biome do continue
			return (px - world.biomes.origin_pixel_x) * cpp,
				(py - world.biomes.origin_pixel_y) * cpp,
				true
		}
	}
	return 0, 0, false
}

@(private = "file")
shot_plot :: proc(shot: Shot, pixels: []rl.Color, width, height, tx, ty: i32, color: rl.Color) {
	if tx < 0 || ty < 0 do return
	x0 := tx * shot.scale
	y0 := ty * shot.scale
	if x0 >= width || y0 >= height do return

	for y in y0 ..< min(y0 + shot.scale, height) {
		for x in x0 ..< min(x0 + shot.scale, width) {
			p := &pixels[int(y) * int(width) + int(x)]
			p^ = blend_over(color, p^)
		}
	}
}

@(private = "file")
shot_draw_glow :: proc(
	shot: Shot,
	pixels: []rl.Color,
	width, height: i32,
	wx, wy: f32,
	halo, blaze: i32,
	peak: f32,
	wide_color, core_color: rl.Color,
) {
	tx := floor_div(i32(math.floor(wx)) - shot.view.x, shot.view.step)
	ty := floor_div(i32(math.floor(wy)) - shot.view.y, shot.view.step)
	if tx < -halo || ty < -halo || tx > shot.view.w + halo || ty > shot.view.h + halo do return

	for dy in -halo ..= halo {
		for dx in -halo ..= halo {
			away := dx * dx + dy * dy
			if away <= blaze * blaze {
				shot_plot(shot, pixels, width, height, tx + dx, ty + dy, core_color)
				continue
			}
			fade := light_halo_fade(away, halo, peak)
			if fade <= 0 do continue
			shot_plot(shot, pixels, width, height, tx + dx, ty + dy, rl.Fade(wide_color, fade))
		}
	}
}

@(private = "file")
shot_draw_crystals :: proc(shot: Shot, pixels: []rl.Color, width, height: i32) {
	for i in 0 ..< int(shot.light.count) {
		c := shot.light.crystals[i]
		shot_draw_glow(
			shot, pixels, width, height, c.x, c.y,
			LIGHT_CRYSTAL_HALO, LIGHT_CRYSTAL_BLAZE, LIGHT_CRYSTAL_PEAK,
			LIGHT_GLOW, LIGHT_CORE,
		)
	}
}

@(private = "file")
shot_draw_fireflies :: proc(shot: Shot, pixels: []rl.Color, width, height: i32) {
	if shot.flies == nil do return

	for i in 0 ..< int(shot.flies.count) {
		f := shot.flies.flies[i]
		shot_draw_glow(
			shot, pixels, width, height, f.x, f.y,
			FIREFLY_HALO, FIREFLY_BLAZE, FIREFLY_PEAK * firefly_glow(f, f64(shot.flies.clock)),
			FIREFLY_GLOW, FIREFLY_CORE,
		)
	}
}

// The drudge sheet, plotted cell by cell the way the player sprite is
// blitted inline in `world_shot` itself — except a drudge is drawn in this
// later pass, alongside the pots and the bangs, because there can be more
// than one of him and `world_shot`'s own per-row loop only ever carries one
// player's frame. `bin/shot` must show him: this is the tool the repo
// judges everything by. See docs/drudge.md, "Looking at him".
@(private = "file")
shot_draw_drudges :: proc(world: World, shot: Shot, pixels: []rl.Color, width, height: i32) {
	if shot.drudges == nil || shot.drudge_sprite.pixels == nil do return

	player, has_player := shot.player.?

	for i in 0 ..< int(shot.drudges.count) {
		d := shot.drudges.drudges[i]
		facing := has_player ? drudge_facing(d, player) : d.dir
		motion := drudge_motion(d)
		column := drudge_sprite_frame(motion, d.anim)

		origin_x, origin_y := drudge_sprite_frame_origin(d)
		for fy in i32(0) ..< DRUDGE_SPRITE_FRAME_H {
			wy := origin_y + fy
			ty := floor_div(wy-shot.view.y, shot.view.step)
			for fx in i32(0) ..< DRUDGE_SPRITE_FRAME_W {
				c := drudge_sprite_pixel(shot.drudge_sprite, motion, column, facing, fx, fy)
				if c.a == 0 do continue
				wx := origin_x + fx
				tx := floor_div(wx-shot.view.x, shot.view.step)
				shot_plot(shot, pixels, width, height, tx, ty, c)
			}
		}

		lx, ly := drudge_lamp_at(d, facing)
		shot_draw_glow(
			shot, pixels, width, height, lx, ly,
			DRUDGE_LAMP_HALO, DRUDGE_LAMP_BLAZE, DRUDGE_LAMP_PEAK,
			drudge_lamp_glow(world.materials), LIGHT_CORE,
		)
	}
}

@(private = "file")
shot_draw_pots :: proc(world: World, shot: Shot, pixels: []rl.Color, width, height: i32, bag: ^Pot_Bag) {
	if bag == nil do return

	for i in 0 ..< int(bag.count) {
		p := bag.pots[i]
		if !p.live do continue

		shot_draw_glow(
			shot, pixels, width, height, p.x, p.y-f32(POT_R),
			POT_FUSE_HALO, POT_FUSE_BLAZE, POT_FUSE_PEAK,
			pot_fuse_glow(world.materials), LIGHT_CORE,
		)
	}
}

@(private = "file")
shot_draw_bangs :: proc(world: World, shot: Shot, pixels: []rl.Color, width, height: i32) {
	if shot.sandbox == nil do return

	sb := shot.sandbox
	for b in sb.bangs.bangs {
		if b.life <= 0 do continue
		glow := f32(bang_power(world.materials, b)) / 255
		shot_draw_glow(
			shot, pixels, width, height,
			f32(sb.origin_x + b.x), f32(sb.origin_y + b.y),
			BANG_HALO, BANG_BLAZE, BANG_PEAK*glow,
			BANG_GLOW, BANG_CORE,
		)
	}
}

@(private = "file")
shot_draw_sparks :: proc(world: World, shot: Shot, pixels: []rl.Color, width, height: i32) {
	if shot.sandbox == nil do return

	sb := shot.sandbox
	for sp in sb.sparks.sparks {
		if sp.life <= 0 do continue
		glow := f32(spark_power(world.materials, sp)) / 255
		shot_draw_glow(
			shot, pixels, width, height,
			f32(sb.origin_x + sp.x), f32(sb.origin_y + sp.y),
			SPARKLE_HALO, SPARKLE_BLAZE, SPARKLE_PEAK*glow,
			SPARKLE_GLOW, SPARKLE_CORE,
		)
	}
}

@(private = "file")
shot_draw_orb :: proc(shot: Shot, pixels: []rl.Color, width, height: i32, p: Player) {
	x, y := light_orb_at(p)
	shot_draw_glow(
		shot, pixels, width, height, x, y,
		LIGHT_ORB_HALO, LIGHT_ORB_BLAZE, LIGHT_ORB_PEAK,
		LIGHT_GLOW, LIGHT_CORE,
	)
}

@(private = "file")
Shot_Line :: enum u8 {
	None,
	Tile,
	Region,
}

@(private = "file")
shot_line_at :: proc(world: World, w: i32, step: i32) -> Shot_Line {
	cpp := world.biomes.cells_per_pixel
	if w - floor_div(w, cpp) * cpp < step do return .Region
	if tile_offset(w) < step do return .Tile
	return .None
}

@(private = "file")
shot_draw_grid :: proc(world: World, shot: Shot, pixels: []rl.Color, width, height: i32) {
	for tx in 0 ..< shot.view.w {
		kind := shot_line_at(world, shot.view.x + tx * shot.view.step, shot.view.step)
		if kind == .None do continue

		color := kind == .Region ? SHOT_REGION_LINE : SHOT_TILE_LINE
		x := tx * shot.scale
		for y in 0 ..< height {
			p := &pixels[int(y) * int(width) + int(x)]
			p^ = blend_over(color, p^)
		}
	}

	for ty in 0 ..< shot.view.h {
		kind := shot_line_at(world, shot.view.y + ty * shot.view.step, shot.view.step)
		if kind == .None do continue

		color := kind == .Region ? SHOT_REGION_LINE : SHOT_TILE_LINE
		y := ty * shot.scale
		for x in 0 ..< width {
			p := &pixels[int(y) * int(width) + int(x)]
			p^ = blend_over(color, p^)
		}
	}
}

@(test)
test_a_shot_holds_the_world_the_generator_makes :: proc(t: ^testing.T) {
	s: Sim
	if !testing.expect(t, sim_load(&s) == .None, "the world must load") do return
	defer sim_unload(&s)

	mine, found := find_biome_index(s.world.biomes, "Coalmine")
	if !testing.expect(t, found) do return

	x, y, aimed := shot_biome_origin(s.world, Biome_Id(mine))
	testing.expect(t, aimed, "the starter map must paint Coalmine somewhere")
	testing.expect(t, world_biome_at(s.world, x, y) == Biome_Id(mine), "the aim must land in the biome")

	shot := Shot {
		view  = World_View{x = x, y = y, w = 24, h = 16, step = 1},
		scale = 2,
	}

	path := "shot_round_trip.tmp.png"
	defer os.remove(path)
	testing.expect(t, world_shot(s.world, shot, path), "the shot must be written")

	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	img := rl.LoadImage(cpath)
	defer rl.UnloadImage(img)
	if !testing.expect(t, img.data != nil, "the shot must load") do return
	testing.expect(t, img.width == 48 && img.height == 32, "scale must multiply both edges")

	colors := rl.LoadImageColors(img)
	defer rl.UnloadImageColors(colors)

	for ty in i32(0) ..< 16 {
		for tx in i32(0) ..< 24 {
			cell := world_cell_at(s.world, x + tx, y + ty)
			want := rl_from_argb(s.world.materials.materials[cell].color)

			for sy in i32(0) ..< 2 {
				for sx in i32(0) ..< 2 {
					got := colors[int(ty * 2 + sy) * 48 + int(tx * 2 + sx)]
					same := want.a == 0 \
					? (got.r == BACKGROUND.r && got.g == BACKGROUND.g && got.b == BACKGROUND.b) \
					: (got.r == want.r && got.g == want.g && got.b == want.b)
					testing.expectf(
						t,
						same,
						"texel %d,%d holds %v but the world says %v",
						tx,
						ty,
						got,
						want,
					)
				}
			}
		}
	}
}

@(test)
test_a_shot_refuses_a_size_it_cannot_draw :: proc(t: ^testing.T) {
	s: Sim
	if !testing.expect(t, sim_load(&s) == .None) do return
	defer sim_unload(&s)

	path := "shot_refused.tmp.png"
	defer os.remove(path)

	testing.expect(t, !world_shot(s.world, Shot{view = {w = 8, h = 8, step = 1}, scale = 0}, path))
	testing.expect(t, !world_shot(s.world, Shot{view = {w = 0, h = 8, step = 1}, scale = 1}, path))
	testing.expect(
		t,
		!world_shot(s.world, Shot{view = {w = 20000, h = 20000, step = 1}, scale = 4}, path),
		"a shot larger than SHOT_MAX_PIXELS is a typo, not a request",
	)
	testing.expect(t, !os.exists(path), "a refused shot must write nothing")
}

@(private = "file")
shot_test_player :: proc(t: ^testing.T, world: World) -> (p: Player, ok: bool) {
	x, y, found := world_find_spawn(world)
	if !testing.expect(t, found, "the shipped map must offer a spawn point") do return {}, false
	return Player{x = f32(x), y = f32(y), facing = 1, on_ground = true}, true
}

@(test)
test_a_shot_with_the_player_differs_from_the_same_shot_without_him :: proc(t: ^testing.T) {
	s: Sim
	if !testing.expect(t, sim_load(&s) == .None, "the world must load") do return
	defer sim_unload(&s)

	sheet, result := load_sprite_sheet(SPRITE_SHEET_PATH)
	if !testing.expectf(t, result.err == .None, "the sprite sheet must load, got %v", result.err) do return
	defer destroy_sprite_sheet(sheet)

	player, ok := shot_test_player(t, s.world)
	if !ok do return

	ox, oy := sprite_frame_origin(player)
	view := World_View{x = ox - 4, y = oy - 4, w = SPRITE_FRAME_W + 8, h = SPRITE_FRAME_H + 8, step = 1}

	without_path := "shot_diff_without_player.tmp.png"
	with_path := "shot_diff_with_player.tmp.png"
	defer os.remove(without_path)
	defer os.remove(with_path)

	testing.expect(t, world_shot(s.world, Shot{view = view, scale = 1}, without_path))
	testing.expect(t, world_shot(s.world, Shot{view = view, scale = 1, player = player, sprite = sheet}, with_path))

	without_bytes, err1 := os.read_entire_file_from_path(without_path, context.allocator)
	defer delete(without_bytes)
	with_bytes, err2 := os.read_entire_file_from_path(with_path, context.allocator)
	defer delete(with_bytes)
	if !testing.expect(t, err1 == nil && err2 == nil, "both shots must be written") do return

	differs := len(without_bytes) != len(with_bytes)
	if !differs {
		for i in 0 ..< len(without_bytes) {
			if without_bytes[i] != with_bytes[i] {
				differs = true
				break
			}
		}
	}
	testing.expect(t, differs, "drawing the player must change the picture")
}

@(test)
test_the_wizards_pixels_land_where_the_body_box_says_they_should :: proc(t: ^testing.T) {
	s: Sim
	if !testing.expect(t, sim_load(&s) == .None, "the world must load") do return
	defer sim_unload(&s)

	sheet, result := load_sprite_sheet(SPRITE_SHEET_PATH)
	if !testing.expectf(t, result.err == .None, "the sprite sheet must load, got %v", result.err) do return
	defer destroy_sprite_sheet(sheet)

	player, ok := shot_test_player(t, s.world)
	if !ok do return

	motion := player_motion(player)
	column := sprite_frame(motion, player.anim)

	ink_x, ink_y := i32(-1), i32(-1)
	find_ink: for fy in i32(SPRITE_BODY_Y) ..< SPRITE_BODY_Y + SPRITE_BODY_H {
		for fx in i32(SPRITE_BODY_X) ..< SPRITE_BODY_X + SPRITE_BODY_W {
			if sprite_pixel(sheet, motion, column, player.facing, fx, fy).a != 0 {
				ink_x, ink_y = fx, fy
				break find_ink
			}
		}
	}
	if !testing.expect(t, ink_x >= 0, "the idle frame must hold at least one opaque pixel inside the body box") do return
	want := sprite_pixel(sheet, motion, column, player.facing, ink_x, ink_y)

	ox, oy := sprite_frame_origin(player)
	wx, wy := ox + ink_x, oy + ink_y

	path := "shot_body_box.tmp.png"
	defer os.remove(path)
	shot := Shot{view = World_View{x = wx, y = wy, w = 1, h = 1, step = 1}, scale = 1, player = player, sprite = sheet}
	if !testing.expect(t, world_shot(s.world, shot, path), "the shot must be written") do return

	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	img := rl.LoadImage(cpath)
	defer rl.UnloadImage(img)
	if !testing.expect(t, img.data != nil, "the shot must load back") do return

	colors := rl.LoadImageColors(img)
	defer rl.UnloadImageColors(colors)
	got := colors[0]

	testing.expectf(
		t,
		got.r == want.r && got.g == want.g && got.b == want.b,
		"the body box's ink at %d,%d must land at world (%d,%d), got %v want %v",
		ink_x, ink_y, wx, wy, got, want,
	)
}

@(test)
test_a_shot_with_the_player_still_writes_a_valid_png_of_the_expected_size :: proc(t: ^testing.T) {
	s: Sim
	if !testing.expect(t, sim_load(&s) == .None, "the world must load") do return
	defer sim_unload(&s)

	sheet, result := load_sprite_sheet(SPRITE_SHEET_PATH)
	if !testing.expectf(t, result.err == .None, "the sprite sheet must load, got %v", result.err) do return
	defer destroy_sprite_sheet(sheet)

	player, ok := shot_test_player(t, s.world)
	if !ok do return

	shot := Shot {
		view   = World_View{x = i32(player.x) - 40, y = i32(player.y) - 40, w = 80, h = 60, step = 1},
		scale  = 3,
		player = player,
		sprite = sheet,
	}

	path := "shot_valid_with_player.tmp.png"
	defer os.remove(path)
	testing.expect(t, world_shot(s.world, shot, path), "a shot with a player must still be written")

	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	img := rl.LoadImage(cpath)
	defer rl.UnloadImage(img)
	testing.expect(t, img.data != nil, "the shot must load back")
	testing.expectf(
		t,
		img.width == 240 && img.height == 180,
		"scale must multiply both edges, got %dx%d",
		img.width,
		img.height,
	)
}

@(test)
test_a_shot_with_ticks_differs_from_the_same_shot_without_them :: proc(t: ^testing.T) {
	s: Sim
	if !testing.expect(t, sim_load(&s) == .None, "the world must load") do return
	defer sim_unload(&s)

	sand, sand_found := find_material_index(s.world.materials, "Sand")
	if !testing.expect(t, sand_found, "Sand must exist") do return

	view := World_View{x = 0, y = -4000, w = 40, h = 40, step = 1}

	err := shot_open_sandbox(&s, view)
	testing.expectf(t, err == .None, "the sandbox must open, got %v", err)
	sandbox_paint(&s.sandbox, s.world.materials, 20, 0, 3, Cell(sand))

	before_path := "shot_ticks_before.tmp.png"
	after_path := "shot_ticks_after.tmp.png"
	defer os.remove(before_path)
	defer os.remove(after_path)

	shot := Shot{view = view, scale = 1, sandbox = &s.sandbox}
	testing.expect(t, world_shot(s.world, shot, before_path), "the before shot must be written")

	sim_run(&s, 200)
	testing.expect(t, world_shot(s.world, shot, after_path), "the after shot must be written")

	before_bytes, err1 := os.read_entire_file_from_path(before_path, context.allocator)
	defer delete(before_bytes)
	after_bytes, err2 := os.read_entire_file_from_path(after_path, context.allocator)
	defer delete(after_bytes)
	if !testing.expect(t, err1 == nil && err2 == nil, "both shots must be written") do return

	differs := len(before_bytes) != len(after_bytes)
	if !differs {
		for i in 0 ..< len(before_bytes) {
			if before_bytes[i] != after_bytes[i] {
				differs = true
				break
			}
		}
	}
	testing.expect(t, differs, "running ticks must change the picture")
}

@(test)
test_shot_open_sandbox_refuses_what_a_sandbox_cannot_hold :: proc(t: ^testing.T) {
	s: Sim
	if !testing.expect(t, sim_load(&s) == .None, "the world must load") do return
	defer sim_unload(&s)

	too_large := World_View{x = 0, y = 0, w = SANDBOX_MAX_WIDTH + 1, h = 64, step = 1}
	testing.expectf(
		t, shot_open_sandbox(&s, too_large) == .Too_Large,
		"a rectangle past SANDBOX_MAX_WIDTH must be refused, not silently clamped",
	)

	coarse_step := World_View{x = 0, y = 0, w = 64, h = 64, step = 2}
	testing.expectf(
		t, shot_open_sandbox(&s, coarse_step) == .Wrong_Step,
		"ticks needs step 1: a sandbox is one cell per cell",
	)
}

@(private = "file")
shot_mean_brightness :: proc(colors: [^]rl.Color, width, x0, y0, w, h: i32) -> u32 {
	total := u32(0)
	for y in y0 ..< y0 + h {
		for x in x0 ..< x0 + w {
			c := colors[int(y) * int(width) + int(x)]
			total += u32(c.r) + u32(c.g) + u32(c.b)
		}
	}
	return total / u32(w * h * 3)
}

@(test)
test_the_orb_lights_what_is_near_him_and_the_gloom_keeps_the_rest :: proc(t: ^testing.T) {
	s: Sim
	if !testing.expect(t, sim_load(&s) == .None, "the world must load") do return
	defer sim_unload(&s)
	sim_play_begin(&s)

	sheet, result := load_sprite_sheet(SPRITE_SHEET_PATH)
	if !testing.expectf(t, result.err == .None, "the shipped sheet must load, got %v", result.err) do return
	defer destroy_sprite_sheet(sheet)

	for _ in 0 ..< 30 do sim_step_player(&s, {}, false)

	player := s.player
	view := World_View{x = i32(player.x) - 160, y = i32(player.y) - 90, w = 320, h = 180, step = 1}
	shot := Shot{view = view, scale = 1, player = player, sprite = sheet, sandbox = &s.sandbox}

	dim_path := "shot_gloom_off.tmp.png"
	lit_path := "shot_gloom_on.tmp.png"
	defer os.remove(dim_path)
	defer os.remove(lit_path)

	if !testing.expect(t, world_shot(s.world, shot, dim_path), "the unlit shot must be written") do return
	shot.light = &s.light
	if !testing.expect(t, world_shot(s.world, shot, lit_path), "the lit shot must be written") do return

	read :: proc(t: ^testing.T, path: string) -> (rl.Image, [^]rl.Color, bool) {
		cpath := strings.clone_to_cstring(path, context.temp_allocator)
		img := rl.LoadImage(cpath)
		if !testing.expectf(t, img.data != nil, "%s must load back", path) do return img, nil, false
		return img, rl.LoadImageColors(img), true
	}

	dim_img, dim, dim_ok := read(t, dim_path)
	defer rl.UnloadImage(dim_img)
	defer rl.UnloadImageColors(dim)
	lit_img, lit, lit_ok := read(t, lit_path)
	defer rl.UnloadImage(lit_img)
	defer rl.UnloadImageColors(lit)
	if !dim_ok || !lit_ok do return

	lit_near := shot_mean_brightness(lit, view.w, 140, 70, 40, 40)
	lit_far := shot_mean_brightness(lit, view.w, 0, 0, 40, 40)
	dim_far := shot_mean_brightness(dim, view.w, 0, 0, 40, 40)

	testing.expectf(
		t, lit_near > 2 * lit_far,
		"the cells he stands among must read far brighter than the far corner, got %d against %d",
		lit_near, lit_far,
	)
	testing.expectf(
		t, lit_far < dim_far,
		"the far corner must be darker for the light being on, got %d against %d",
		lit_far, dim_far,
	)
}
