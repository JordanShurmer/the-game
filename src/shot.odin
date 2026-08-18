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
*/

// A shot has to fit in memory and in a reader. This is far past what
// any view needs and still stops a typo from asking for a gigabyte.
SHOT_MAX_PIXELS :: 8192 * 8192

Shot :: struct {
	view:  World_View,
	scale: i32,  // image pixels along one edge of a texel; 1 or more
	grid:  bool, // draw the tile lattice and the region borders
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
	generate(world, shot.view, cells)

	// One color per material, composited once instead of per pixel.
	lut: [256]rl.Color
	for m, i in world.materials.materials {
		lut[i] = shot_over_background(rl_from_argb(m.color))
	}

	pixels := make([]rl.Color, int(width) * int(height))
	defer delete(pixels)

	for ty in 0 ..< shot.view.h {
		row := cells[int(ty) * int(shot.view.w):][:shot.view.w]
		for sy in 0 ..< shot.scale {
			line := pixels[int(ty * shot.scale + sy) * int(width):][:width]
			for tx in 0 ..< shot.view.w {
				c := lut[row[tx]]
				for sx in 0 ..< shot.scale {
					line[tx * shot.scale + sx] = c
				}
			}
		}
	}

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

// Air is transparent, so it shows what is behind the world. That is
// the window background, and a shot says the same thing.
@(private = "file")
shot_over_background :: proc(c: rl.Color) -> rl.Color {
	if c.a == 255 do return c

	over :: proc(fg, bg: u8, a: f32) -> u8 {
		return u8(f32(fg) * a + f32(bg) * (1 - a))
	}

	a := f32(c.a) / 255
	return rl.Color {
		over(c.r, BACKGROUND.r, a),
		over(c.g, BACKGROUND.g, a),
		over(c.b, BACKGROUND.b, a),
		255,
	}
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
	blend :: proc(dst: ^rl.Color, line: rl.Color) {
		a := f32(line.a) / 255
		over :: proc(fg, bg: u8, a: f32) -> u8 {
			return u8(f32(fg) * a + f32(bg) * (1 - a))
		}
		dst.r = over(line.r, dst.r, a)
		dst.g = over(line.g, dst.g, a)
		dst.b = over(line.b, dst.b, a)
	}

	for tx in 0 ..< shot.view.w {
		kind := shot_line_at(world, shot.view.x + tx * shot.view.step, shot.view.step)
		if kind == .None do continue

		color := kind == .Region ? SHOT_REGION_LINE : SHOT_TILE_LINE
		x := tx * shot.scale
		for y in 0 ..< height do blend(&pixels[int(y) * int(width) + int(x)], color)
	}

	for ty in 0 ..< shot.view.h {
		kind := shot_line_at(world, shot.view.y + ty * shot.view.step, shot.view.step)
		if kind == .None do continue

		color := kind == .Region ? SHOT_REGION_LINE : SHOT_TILE_LINE
		y := ty * shot.scale
		for x in 0 ..< width do blend(&pixels[int(y) * int(width) + int(x)], color)
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
