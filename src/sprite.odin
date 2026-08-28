package game

import "core:math"
import "core:os"
import "core:strings"
import "core:testing"
import rl "vendor:raylib"

SPRITE_FRAME_W :: 24
SPRITE_FRAME_H :: 32
SPRITE_COLUMNS :: 6
SPRITE_ROWS :: 6

SPRITE_BODY_X :: 8
SPRITE_BODY_Y :: 11
SPRITE_BODY_W :: 8
SPRITE_BODY_H :: 13

#assert(SPRITE_BODY_W == PLAYER_BODY_W, "the sprite's body box and the player's collision box must be the same width")
#assert(SPRITE_BODY_H == PLAYER_BODY_H, "the sprite's body box and the player's collision box must be the same height")

SPRITE_SHEET_PATH :: "data/sprites/wizard.png"

Sprite_Sheet :: struct {
	pixels: []rl.Color,
	width:  i32,
	height: i32,
}

Sprite_Load_Error :: enum u8 {
	None,
	File_Unreadable,
	Wrong_Size,
}

Sprite_Load_Result :: struct {
	err: Sprite_Load_Error,
}

// The wizard's own sheet size is the default, so every existing caller reads
// unchanged. A sibling sheet with a different frame size and grid — the
// drudge's own, drawn by tools/seed_drudge.py — passes its own numbers
// instead of duplicating this whole procedure for one different check.
load_sprite_sheet :: proc(
	path: string,
	frame_w := i32(SPRITE_FRAME_W),
	frame_h := i32(SPRITE_FRAME_H),
	columns := i32(SPRITE_COLUMNS),
	rows := i32(SPRITE_ROWS),
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

	want_w := frame_w * columns
	want_h := frame_h * rows
	if img.width != want_w || img.height != want_h {
		return {}, {err = .Wrong_Size}
	}

	loaded := rl.LoadImageColors(img)
	defer rl.UnloadImageColors(loaded)

	pixels := make([]rl.Color, int(want_w) * int(want_h), allocator)
	for i in 0 ..< len(pixels) do pixels[i] = loaded[i]

	return Sprite_Sheet{pixels = pixels, width = want_w, height = want_h}, {}
}

destroy_sprite_sheet :: proc(sheet: Sprite_Sheet, allocator := context.allocator) {
	delete(sheet.pixels, allocator)
}

SPRITE_ROW_FRAMES := [Player_Motion]int {
	.Idle = 4,
	.Walk = 6,
	.Run  = 6,
	.Rise = 2,
	.Fall = 2,
	.Jet  = 4,
}

@(private = "file")
SPRITE_ROW_FPS := [Player_Motion]f32 {
	.Idle = 2,
	.Walk = 8,
	.Run  = 12,
	.Rise = 6,
	.Fall = 6,
	.Jet  = 10,
}

sprite_frame :: proc(motion: Player_Motion, anim: f32) -> (column: int) {
	frames := SPRITE_ROW_FRAMES[motion]
	fps := SPRITE_ROW_FPS[motion]

	clock := max(anim, 0)
	f := int(math.mod(clock * fps, f32(frames)))
	return clamp(f, 0, frames - 1)
}

sprite_pixel :: proc(sheet: Sprite_Sheet, motion: Player_Motion, column: int, facing: i8, x, y: i32) -> rl.Color {
	if x < 0 || y < 0 || x >= SPRITE_FRAME_W || y >= SPRITE_FRAME_H do return {}
	if column < 0 || column >= SPRITE_COLUMNS do return {}

	sx := facing < 0 ? SPRITE_FRAME_W - 1 - x : x
	fx := i32(column) * SPRITE_FRAME_W + sx
	fy := i32(motion) * SPRITE_FRAME_H + y
	return sheet.pixels[fy * sheet.width + fx]
}

sprite_frame_origin :: proc(p: Player) -> (x, y: i32) {
	x = i32(math.floor(p.x)) - SPRITE_FRAME_W / 2
	y = i32(math.floor(p.y)) - (SPRITE_BODY_Y + SPRITE_BODY_H)
	return
}

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
		for anim < 500 {
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
	defer destroy_sprite_sheet(sheet)

	testing.expect(t, result.err == .File_Unreadable)
	testing.expect(t, sheet.pixels == nil, "a failed load must not hand back pixels")
}

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
