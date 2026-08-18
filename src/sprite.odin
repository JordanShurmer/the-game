package game

import "core:math"
import "core:os"
import "core:strings"
import "core:testing"
import rl "vendor:raylib"

/*
The wizard sprite: a picture of the player, not a fact about him.

tools/seed_wizard.py draws data/sprites/wizard.png the same way
seed_tiles.py draws a tile set: a grid where a row is an animation and
a column is a frame of it. This file is the game's half of that
contract. It loads the sheet, picks a frame from Player_Motion and an
animation clock, and reads one pixel of it with facing already
applied, so bin/shot and, later, the game window read one frame the
same way and can never quietly disagree about which pixel is his
elbow.

The trade this file makes, on purpose: a tile PNG matches every pixel
against the material table, because a tile cell has to become a real
Cell the generator can draw with. A sprite pixel never becomes a Cell.
It only ever becomes a screen pixel, so the only thing that matters
about it is whether it is there at all. Alpha 0 is transparent and
alpha 255 is ink, and nothing here asks what color it is. This is
worth saying plainly, because it is an easy rule to import from
tile_png.odin by habit and get backward: a sprite loader that rejected
an unmatched color would refuse to load its own art.

The size of a frame, and where the body box sits inside it, are not
this file's numbers to pick. They come from tools/seed_wizard.py,
which drew the sheet to them, and from PLAYER_BODY_W/H in player.odin,
which the #asserts below hold this file to. Move one without the
other and the wizard's feet stop meeting the floor he is standing on,
which docs/player.md calls out as the whole reason those numbers are
not a free choice anywhere in this codebase.
*/

// One frame, and the grid the sheet lays them out in. These match
// FRAME_W, FRAME_H, COLUMNS and ROWS at the top of tools/seed_wizard.py
// exactly. The shipped sheet is 144x192, and the load test below
// multiplies these out and checks the file on disk agrees.
SPRITE_FRAME_W :: 24
SPRITE_FRAME_H :: 32
SPRITE_COLUMNS :: 6
SPRITE_ROWS :: 6

// Where the wizard collides, inside one frame. tools/seed_wizard.py
// holds the same four numbers under the same names, and player.odin
// holds PLAYER_BODY_W and PLAYER_BODY_H: the same box, in world cells
// instead of frame pixels. The #asserts below are the guard docs/
// player.md asks for: the art and the collision box must not drift
// apart silently, because a drift there is exactly the kind of bug a
// picture does not catch until a player is already standing knee-deep
// in a wall that looks fine.
SPRITE_BODY_X :: 8
SPRITE_BODY_Y :: 11
SPRITE_BODY_W :: 8
SPRITE_BODY_H :: 13

// The row of the frame his feet stand on: the bottom of the body box.
// Named because docs/player.md's table names it, not because anything
// below reads it under this name instead of the sum it already is.
SPRITE_FOOT_Y :: SPRITE_BODY_Y + SPRITE_BODY_H - 1

#assert(SPRITE_BODY_W == PLAYER_BODY_W, "the sprite's body box and the player's collision box must be the same width")
#assert(SPRITE_BODY_H == PLAYER_BODY_H, "the sprite's body box and the player's collision box must be the same height")

// Where the sheet lives on disk. bin/shot and the game window both
// load through this path, so reseeding the art only ever means running
// tools/seed_wizard.py again, never editing a path in two places.
SPRITE_SHEET_PATH :: "data/sprites/wizard.png"

/*
A loaded sheet: every pixel of data/sprites/wizard.png, and the size of
the grid it is laid out on.

Pixels are rl.Color, not the 0xAARRGGBB u32 color.odin's helpers deal
in. Every reader of this data composites it straight into an rl.Color
pixel buffer (world_shot today, the game window later), which is the
hot path this sits on: once per pixel of every frame drawn, not once
per load. Storing it already unpacked skips a shift-and-mask there for
a struct that gets no other use out of packing into one u32. The
material table stores the packed form instead, because a Cell is a
small id and matching a pixel against a table of them is what
tile_png.odin does with it; a sprite pixel is read, never matched.
*/
Sprite_Sheet :: struct {
	pixels: []rl.Color, // width * height, row-major, one full sheet
	width:  i32,
	height: i32,
}

Sprite_Load_Error :: enum u8 {
	None,
	File_Unreadable,
	Wrong_Size, // not SPRITE_FRAME_W*SPRITE_COLUMNS by SPRITE_FRAME_H*SPRITE_ROWS
}

// width and height report the size actually found, when err is
// Wrong_Size, so a reseed that gets the grid wrong says how by how
// much.
Sprite_Load_Result :: struct {
	width:  i32,
	height: i32,
	err:    Sprite_Load_Error,
}

/*
Load the sheet, the way load_tile_png loads a tile: rl.LoadImage and
rl.LoadImageColors, which need no window. Unlike a tile, nothing here
is checked against the material table; the sheet is trusted to be
whatever tools/seed_wizard.py drew, and the only check below is the
shape of the grid, never the color of a pixel.
*/
load_sprite_sheet :: proc(
	path: string,
	allocator := context.allocator,
) -> (
	sheet: Sprite_Sheet,
	result: Sprite_Load_Result,
) {
	if !os.exists(path) do return {}, {err = .File_Unreadable}

	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	defer delete(cpath, context.temp_allocator)

	img := rl.LoadImage(cpath)
	if img.data == nil || img.width <= 0 || img.height <= 0 {
		return {}, {err = .File_Unreadable}
	}
	defer rl.UnloadImage(img)

	want_w := i32(SPRITE_FRAME_W * SPRITE_COLUMNS)
	want_h := i32(SPRITE_FRAME_H * SPRITE_ROWS)
	if img.width != want_w || img.height != want_h {
		return {}, {err = .Wrong_Size, width = img.width, height = img.height}
	}

	// LoadImageColors normalises any source format to RGBA8.
	loaded := rl.LoadImageColors(img)
	defer rl.UnloadImageColors(loaded)

	// The sheet must outlive this call and be freed the same way every
	// other allocation in this codebase is, so the raylib buffer is
	// copied into one this file owns rather than handed back directly.
	pixels := make([]rl.Color, int(want_w) * int(want_h), allocator)
	for i in 0 ..< len(pixels) do pixels[i] = loaded[i]

	return Sprite_Sheet{pixels = pixels, width = want_w, height = want_h}, {}
}

destroy_sprite_sheet :: proc(sheet: Sprite_Sheet, allocator := context.allocator) {
	delete(sheet.pixels, allocator)
}

// Frames per row, indexed by Player_Motion. This mirrors ROW_FRAMES in
// tools/seed_wizard.py exactly, in both count and order: Player_Motion
// is the contract player.odin documents between the two, row for row.
// A table that under-counted a row would make sprite_frame stop short
// of art that is there; one that over-counted would read into the
// blank columns seed_wizard.py --check guarantees stay transparent.
SPRITE_ROW_FRAMES := [Player_Motion]int {
	.Idle = 4,
	.Walk = 6,
	.Run  = 6,
	.Rise = 2,
	.Fall = 2,
	.Jet  = 4,
}

// How fast each row plays, in frames per second of Player.anim. Idle
// is a breath and barely moves; a run cycles faster than a walk, the
// way a stride does; the jet beat is quick because the flame under him
// is.
@(private = "file")
SPRITE_ROW_FPS := [Player_Motion]f32 {
	.Idle = 2,
	.Walk = 8,
	.Run  = 12,
	.Rise = 6,
	.Fall = 6,
	.Jet  = 10,
}

/*
Pick a column from the animation clock.

The result is always inside the row's declared frame count. math.mod
keeps it there arithmetically: its result carries the sign of its
first argument, and the clock is never negative, so it lands in
[0, frames). The clamp below is the belt to that brace, so a caller can
never read past art that is not there even if a future row's fps and
frame count round awkwardly against each other at the edge of a float.
*/
sprite_frame :: proc(motion: Player_Motion, anim: f32) -> (column: int) {
	frames := SPRITE_ROW_FRAMES[motion]
	fps := SPRITE_ROW_FPS[motion]

	// Player.anim only ever grows, but a caller must not get a negative
	// index if it hands one in anyway.
	clock := max(anim, 0)
	f := int(math.mod(clock * fps, f32(frames)))
	return clamp(f, 0, frames - 1)
}

/*
One pixel of one frame, with facing already applied.

x and y are frame-local: 0..<SPRITE_FRAME_W across, 0..<SPRITE_FRAME_H
down. Every frame in the sheet faces right; a left-facing wizard is the
same frame read back to front about the frame's own centre column, not
about the body box's centre, which is why SPRITE_BODY_X keeps the box
centred in the frame in the first place. Doing the mirror once, here,
is what stops bin/shot and the game window from ever disagreeing about
which side of him is which.

column and motion outside their declared range read as fully
transparent rather than into a neighbour's art, so a caller that passes
a bad one gets nothing drawn instead of the wrong thing drawn.
*/
sprite_pixel :: proc(sheet: Sprite_Sheet, motion: Player_Motion, column: int, facing: i8, x, y: i32) -> rl.Color {
	if x < 0 || y < 0 || x >= SPRITE_FRAME_W || y >= SPRITE_FRAME_H do return {}
	if column < 0 || column >= SPRITE_COLUMNS do return {}

	sx := facing < 0 ? SPRITE_FRAME_W - 1 - x : x
	fx := i32(column) * SPRITE_FRAME_W + sx
	fy := i32(motion) * SPRITE_FRAME_H + y
	return sheet.pixels[fy * sheet.width + fx]
}

/*
The world cell the frame's top-left pixel falls on, given the player's
feet.

The frame is centred on the body box across (SPRITE_FRAME_W/2 lands on
SPRITE_BODY_X + SPRITE_BODY_W/2, which is what makes the mirror in
sprite_pixel sound), and it reaches SPRITE_BODY_Y rows above the box
for the hat and the staff head and SPRITE_FRAME_H - SPRITE_BODY_Y -
SPRITE_BODY_H rows below it for the jetpack flame. Both ends use
floor(p.x) and floor(p.y), the same rounding player.odin's own
body-bounds procs use, so the frame and the body he actually collides
with always agree about which world cell is which, whatever the
fractional part of his position happens to be.
*/
sprite_frame_origin :: proc(p: Player) -> (x, y: i32) {
	x = i32(math.floor(p.x)) - SPRITE_FRAME_W / 2
	y = i32(math.floor(p.y)) - (SPRITE_BODY_Y + SPRITE_BODY_H)
	return
}

// ------------------------------------------------------------
// Tests (run with: odin test src  from repo root)
// ------------------------------------------------------------

@(test)
test_the_shipped_sheet_loads_at_the_declared_size :: proc(t: ^testing.T) {
	sheet, result := load_sprite_sheet(SPRITE_SHEET_PATH)
	if !testing.expectf(t, result.err == .None, "the shipped sheet must load, got %v", result.err) do return
	defer destroy_sprite_sheet(sheet)

	testing.expectf(
		t,
		sheet.width == SPRITE_FRAME_W * SPRITE_COLUMNS && sheet.height == SPRITE_FRAME_H * SPRITE_ROWS,
		"the sheet must be %dx%d, got %dx%d",
		SPRITE_FRAME_W * SPRITE_COLUMNS,
		SPRITE_FRAME_H * SPRITE_ROWS,
		sheet.width,
		sheet.height,
	)
}

/*
The rule tools/seed_wizard.py --check enforces on the file: every frame
a row declares holds ink, and every frame past that count in the same
row holds none. Mirrored here so a reseed that breaks the rule fails
odin test src as well as the tool's own gate, and a game that only ever
reads through sprite_pixel catches it too.
*/
@(test)
test_every_declared_frame_holds_ink_and_every_undeclared_frame_is_empty :: proc(t: ^testing.T) {
	sheet, result := load_sprite_sheet(SPRITE_SHEET_PATH)
	if !testing.expectf(t, result.err == .None, "the shipped sheet must load, got %v", result.err) do return
	defer destroy_sprite_sheet(sheet)

	for motion in Player_Motion {
		declared := SPRITE_ROW_FRAMES[motion]
		for column in 0 ..< SPRITE_COLUMNS {
			ink := 0
			for y in i32(0) ..< SPRITE_FRAME_H {
				for x in i32(0) ..< SPRITE_FRAME_W {
					if sprite_pixel(sheet, motion, column, 1, x, y).a != 0 do ink += 1
				}
			}

			if column < declared {
				testing.expectf(t, ink > 0, "%v frame %d is empty, and the row declares it", motion, column)
			} else {
				testing.expectf(t, ink == 0, "%v frame %d holds ink, and the row does not declare it", motion, column)
			}
		}
	}
}

@(test)
test_the_body_box_is_centred_in_the_frame_and_stays_inside_it :: proc(t: ^testing.T) {
	testing.expect(
		t,
		SPRITE_BODY_X >= 0 && SPRITE_BODY_X + SPRITE_BODY_W <= SPRITE_FRAME_W,
		"the body box must fit inside the frame across",
	)
	testing.expect(
		t,
		SPRITE_BODY_Y >= 0 && SPRITE_BODY_Y + SPRITE_BODY_H <= SPRITE_FRAME_H,
		"the body box must fit inside the frame down",
	)
	testing.expectf(
		t,
		2 * SPRITE_BODY_X + SPRITE_BODY_W == SPRITE_FRAME_W,
		"the body box must be centred across the frame, or mirroring reads as a different wizard",
	)
}

@(test)
test_sprite_frame_never_returns_a_column_the_row_does_not_declare :: proc(t: ^testing.T) {
	for motion in Player_Motion {
		declared := SPRITE_ROW_FRAMES[motion]
		anim := f32(0)
		for anim < 500 { // several minutes of clock, at every row's own rate
			column := sprite_frame(motion, anim)
			testing.expectf(
				t,
				column >= 0 && column < declared,
				"%v at anim=%f returned column %d, past the %d frames the row declares",
				motion,
				anim,
				column,
				declared,
			)
			anim += 0.01
		}
	}
}

@(test)
test_loading_a_missing_sprite_sheet_fails_cleanly :: proc(t: ^testing.T) {
	sheet, result := load_sprite_sheet("data/sprites/no_such_wizard.png")
	defer destroy_sprite_sheet(sheet) // nil pixels; delete on a nil slice is a no-op

	testing.expect(t, result.err == .File_Unreadable)
	testing.expect(t, sheet.pixels == nil, "a failed load must not hand back pixels")
}

// The mirror sprite_pixel does for a left-facing frame must be exactly
// the right-facing frame read back to front about its own centre
// column, for every pixel, not just the ones an author happened to
// look at.
@(test)
test_a_left_facing_frame_is_the_right_facing_frame_read_back_to_front :: proc(t: ^testing.T) {
	sheet, result := load_sprite_sheet(SPRITE_SHEET_PATH)
	if !testing.expectf(t, result.err == .None, "the shipped sheet must load, got %v", result.err) do return
	defer destroy_sprite_sheet(sheet)

	for y in i32(0) ..< SPRITE_FRAME_H {
		for x in i32(0) ..< SPRITE_FRAME_W {
			right := sprite_pixel(sheet, .Idle, 0, 1, x, y)
			left := sprite_pixel(sheet, .Idle, 0, -1, SPRITE_FRAME_W - 1 - x, y)
			testing.expectf(
				t,
				right.r == left.r && right.g == left.g && right.b == left.b && right.a == left.a,
				"pixel %d,%d must mirror about the frame's centre column",
				x,
				y,
			)
		}
	}
}
