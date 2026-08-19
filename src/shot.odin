package game

import "core:os"
import "core:strings"
import "core:testing"
import rl "vendor:raylib"

/*
A picture of the world, with no window in it.

The game window is the only other thing that draws the world, and it
draws it this way: ask the generator for the rectangle, then turn
material ids into colors through one table. A shot does the same, so
what a shot shows is what a player sees. It needs no window, no
display, and no graphics driver, which is what makes it the way to
look at the world from a terminal or from a test.

Use it to judge what an edit did. A tile set is 32 pictures and a
biome is a lattice of them; neither reads as a cave system until it is
drawn at size, so draw it and look.

The wizard draws the same way. He is optional and carried on Shot
itself, not a second argument to world_shot: the proc still takes
exactly one World, one Shot and one path, and everything about whether
and how to draw him lives inside the Shot the caller already builds.

The sandbox follows the same rule, for the same reason. `ticks=` on
`bin/shot` (docs/physics.md, "Looking at it") needs to draw what the
physics did, not what the generator would still say is there, and
`world_shot` learns this without a second code path: when shot.sandbox
is set, the fill loop below reads sandbox_cell instead of calling
generate. The caller (cmd/shot/main.odin) is the one that opens the
sandbox, runs the ticks, and points shot.sandbox at it; world_shot
itself only ever reads, never steps.

Three compositing choices are worth saying outright, because a picture
does not explain its own rules:

  - He is point-sampled at whatever step the terrain is sampled at, for
    the same reason the terrain is: at step above 1 he can shrink to a
    few pixels, and that is an honest picture of what a pulled-back
    view can show of anything this small, not a bug to average away.
  - At scale above 1 he is drawn scale times over, the same as every
    texel of terrain, so he does not go soft next to a world that
    stays crisp.
  - He is drawn under the grid, not over it: shot_draw_grid runs after
    he is baked into the pixels, so grid=1 still shows the lattice over
    the whole picture, him included, the way it already shows over
    every material.
*/

// A shot has to fit in memory and in a reader. This is far past what
// any view needs and still stops a typo from asking for a gigabyte.
SHOT_MAX_PIXELS :: 8192 * 8192

Shot :: struct {
	view:    World_View,
	scale:   i32,  // image pixels along one edge of a texel; 1 or more
	grid:    bool, // draw the tile lattice and the region borders
	player:  Maybe(Player), // draw him here, from `sprite`, if set
	sprite:  Sprite_Sheet,  // the wizard sheet; read only when player is set
	sandbox: ^Sandbox, // read cells from here instead of the generator, if set
}

// The lattice, and the borders between regions. Both are drawn over
// the world rather than into it, so they never hide a whole cell.
SHOT_TILE_LINE :: rl.Color{255, 255, 255, 45}
SHOT_REGION_LINE :: rl.Color{255, 210, 90, 130}

/*
Draw a rectangle of the world into a PNG file.

Air is a transparent material. The window shows the background behind
it, so a shot paints it over the same background and the two agree.
*/
world_shot :: proc(world: World, shot: Shot, path: string) -> bool {
	if shot.scale < 1 || shot.view.w <= 0 || shot.view.h <= 0 do return false

	width := shot.view.w * shot.scale
	height := shot.view.h * shot.scale
	if int(width) * int(height) > SHOT_MAX_PIXELS do return false

	cells := make([]Cell, int(shot.view.w) * int(shot.view.h))
	defer delete(cells)
	if shot.sandbox != nil {
		// The physics already ran; read what it left rather than
		// asking the generator, which knows nothing of a tick.
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

	// One color per material, composited once instead of per pixel.
	lut: [256]rl.Color
	for m, i in world.materials.materials {
		lut[i] = blend_over(rl_from_argb(m.color), BACKGROUND)
	}

	// Where the player's frame falls in world cells, and which frame of
	// which row, worked out once rather than per texel. Point-sampled
	// below at whatever step the terrain itself is sampled at; see the
	// header comment for why that is the honest choice above step 1.
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

	for ty in 0 ..< shot.view.h {
		row := cells[int(ty) * int(shot.view.w):][:shot.view.w]
		wy := shot.view.y + ty * shot.view.step
		fy := wy - origin_y
		in_frame_row := has_player && fy >= 0 && fy < SPRITE_FRAME_H

		for sy in 0 ..< shot.scale {
			line := pixels[int(ty * shot.scale + sy) * int(width):][:width]
			for tx in 0 ..< shot.view.w {
				c := lut[row[tx]]

				if in_frame_row {
					wx := shot.view.x + tx * shot.view.step
					fx := wx - origin_x
					if fx >= 0 && fx < SPRITE_FRAME_W {
						sc := sprite_pixel(shot.sprite, motion, column, player.facing, fx, fy)
						if sc.a != 0 do c = blend_over(sc, c)
					}
				}

				for sx in 0 ..< shot.scale {
					line[tx * shot.scale + sx] = c
				}
			}
		}
	}

	// Drawn last, over the player as well as the terrain, so grid=1
	// shows the lattice over the whole picture rather than under him.
	if shot.grid do shot_draw_grid(world, shot, pixels, width, height)

	// The image borrows our buffer, so raylib must not free it.
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

// Why shot_open_sandbox refused to open. See docs/physics.md, "Looking
// at it": ticks=N needs the exact rectangle the shot asks for to be a
// sandbox, and a sandbox has rules a picture alone does not.
Shot_Sandbox_Error :: enum u8 {
	None,
	Too_Large,   // the rectangle does not fit SANDBOX_MAX_WIDTH/HEIGHT
	Wrong_Step,  // step is not 1: a sandbox is one cell per cell
	Open_Failed, // sim_open_sandbox itself refused
}

/*
Open a sandbox on exactly the rectangle a shot asks for.

This is the whole of what `ticks=` needs beyond world_shot itself and
a call to sim_run, pulled out of cmd/shot/main.odin so odin test src
can drive it directly rather than only through the command line tool.
The caller still runs the ticks (sim_run) and any ignite or explode
command (sim_apply) itself, in that order, and then points
Shot.sandbox at s.sandbox before calling world_shot: this proc only
ever opens.
*/
shot_open_sandbox :: proc(s: ^Sim, view: World_View) -> Shot_Sandbox_Error {
	if view.step != 1 do return .Wrong_Step
	if view.w > SANDBOX_MAX_WIDTH || view.h > SANDBOX_MAX_HEIGHT do return .Too_Large
	if sim_open_sandbox(s, view.w, view.h, view.x, view.y, 1, 0) != .None do return .Open_Failed
	return .None
}

/*
The world cell a shot of one region starts at.

A biome name is easier to aim with than a coordinate, and the first
region the map gives that biome is as good as any other, because the
set draws through all of them.
*/
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

/*
Alpha-composite fg over bg. The result always carries full alpha: a
shot is a flat picture, and nothing behind it is ever drawn afterward.

One proc, used three ways: air over the window background, the wizard
over whatever terrain is already at his texel, and a grid line over
the whole picture once that terrain and that wizard are both baked in.
Three call sites for the same blend is what makes it worth pulling out
rather than writing the formula a third time slightly differently.
*/
@(private = "file")
blend_over :: proc(fg, bg: rl.Color) -> rl.Color {
	if fg.a == 255 do return fg

	over :: proc(fg, bg: u8, a: f32) -> u8 {
		return u8(f32(fg) * a + f32(bg) * (1 - a))
	}

	a := f32(fg.a) / 255
	return rl.Color{over(fg.r, bg.r, a), over(fg.g, bg.g, a), over(fg.b, bg.b, a), 255}
}

@(private = "file")
Shot_Line :: enum u8 {
	None,
	Tile,
	Region,
}

/*
Whether a border falls on the texel at this world coordinate.

A region border is also a tile border, because a region is a whole
number of tiles, so the region wins where they meet. Above step 1 a
border can fall between two samples, and the texel that carries it is
the first one past it.
*/
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

// ------------------------------------------------------------
// Tests
// ------------------------------------------------------------

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

	// Read it back and compare it with the generator. A shot that does
	// not agree with the world is worse than no shot: it would send an
	// author to fix a cave that is not there.
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

			// Every pixel of the block a texel covers holds that texel.
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

// A spawned wizard for a test to draw, standing rather than mid-fall:
// player_spawn already checked the ground under his feet, and a shot
// draws one instant with no physics tick to discover on_ground for
// itself the way player_step would on the game's first tick.
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

	// Centred on the frame itself, not just on his feet, so the shot
	// actually holds the picture of him and not just the air above
	// where he stands.
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

/*
Finds one opaque pixel of the idle frame inside the body box, then
checks that world_shot puts the wizard's ink at the exact world cell
sprite_frame_origin and sprite_pixel say it belongs at, rather than
trusting the two procs and the compositing loop to agree by
construction. No pixel is hard-coded: the drawing is procedural and
authored data can change under this test, so the pixel to look for is
found the same way world_shot would find it.
*/
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

	motion := player_motion(player) // .Idle: on_ground is true and vx is 0
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

/*
The point of `ticks=`: a shot taken after the physics ran must not be
the same picture as a shot taken before it. Sand is painted at the top
of an Air-filled rectangle so gravity gives a scene that certainly
moves, the same shape test_a_shot_with_the_player_differs_from_the_same_shot_without_him
uses for the player.
*/
@(test)
test_a_shot_with_ticks_differs_from_the_same_shot_without_them :: proc(t: ^testing.T) {
	s: Sim
	if !testing.expect(t, sim_load(&s) == .None, "the world must load") do return
	defer sim_unload(&s)

	sand, sand_found := find_material_index(s.world.materials, "Sand")
	if !testing.expect(t, sand_found, "Sand must exist") do return

	// Inside the Sky biome, which fills with Air, so nothing behind the
	// sandbox hides the fall (the same coordinate test_tick_runs_the_
	// queued_command in mcp_tools.odin already trusts for this).
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
