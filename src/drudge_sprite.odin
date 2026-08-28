package game

import "core:math"
import "core:testing"
import rl "vendor:raylib"

// The drudge's own sheet, drawn by tools/seed_drudge.py. This is
// src/sprite.odin's own pattern, held to a second grid and a second body
// box, not src/sprite.odin generalised to carry it: the two sheets share a
// PNG reader (`load_sprite_sheet`, parameterised for exactly this reason)
// but a different frame size, a different row count, and a different
// motion enum with different names. Threading a wizard-shaped or
// drudge-shaped switch through every draw call in src/sprite.odin would
// have cost more than this file does, for a sheet only two things (`Drudge`
// and this file) ever ask a question of.
DRUDGE_SPRITE_FRAME_W :: 22
DRUDGE_SPRITE_FRAME_H :: 26
DRUDGE_SPRITE_COLUMNS :: 6
DRUDGE_SPRITE_ROWS :: 3

DRUDGE_SPRITE_BODY_X :: 6
DRUDGE_SPRITE_BODY_Y :: 9
DRUDGE_SPRITE_BODY_W :: 10
DRUDGE_SPRITE_BODY_H :: 12

#assert(DRUDGE_SPRITE_BODY_W == DRUDGE_BODY_W, "the drudge sprite's body box and his collision box must be the same width")
#assert(DRUDGE_SPRITE_BODY_H == DRUDGE_BODY_H, "the drudge sprite's body box and his collision box must be the same height")

DRUDGE_SPRITE_SHEET_PATH :: "data/sprites/drudge.png"

DRUDGE_SPRITE_ROW_FRAMES := [Drudge_Motion]int {
	.Idle  = 3,
	.Walk  = 6,
	.Throw = 3,
}

@(private = "file")
DRUDGE_SPRITE_ROW_FPS := [Drudge_Motion]f32 {
	.Idle  = 2,
	.Walk  = 8,
	.Throw = 14,
}

drudge_sprite_frame :: proc(motion: Drudge_Motion, anim: f32) -> (column: int) {
	frames := DRUDGE_SPRITE_ROW_FRAMES[motion]
	fps := DRUDGE_SPRITE_ROW_FPS[motion]

	clock := max(anim, 0)
	f := int(math.mod(clock * fps, f32(frames)))
	return clamp(f, 0, frames - 1)
}

drudge_sprite_pixel :: proc(sheet: Sprite_Sheet, motion: Drudge_Motion, column: int, facing: i8, x, y: i32) -> rl.Color {
	if x < 0 || y < 0 || x >= DRUDGE_SPRITE_FRAME_W || y >= DRUDGE_SPRITE_FRAME_H do return {}
	if column < 0 || column >= DRUDGE_SPRITE_COLUMNS do return {}

	sx := facing < 0 ? DRUDGE_SPRITE_FRAME_W - 1 - x : x
	fx := i32(column) * DRUDGE_SPRITE_FRAME_W + sx
	fy := i32(motion) * DRUDGE_SPRITE_FRAME_H + y
	return sheet.pixels[fy * sheet.width + fx]
}

drudge_sprite_frame_origin :: proc(d: Drudge) -> (x, y: i32) {
	x = i32(math.floor(d.x)) - DRUDGE_SPRITE_FRAME_W / 2
	y = i32(math.floor(d.y)) - (DRUDGE_SPRITE_BODY_Y + DRUDGE_SPRITE_BODY_H)
	return
}

load_drudge_sprite_sheet :: proc(allocator := context.allocator) -> (sheet: Sprite_Sheet, result: Sprite_Load_Result) {
	return load_sprite_sheet(
		DRUDGE_SPRITE_SHEET_PATH,
		DRUDGE_SPRITE_FRAME_W,
		DRUDGE_SPRITE_FRAME_H,
		DRUDGE_SPRITE_COLUMNS,
		DRUDGE_SPRITE_ROWS,
		allocator,
	)
}

@(test)
test_the_shipped_drudge_sheet_loads_at_the_declared_size :: proc(t: ^testing.T) {
	sheet, result := load_drudge_sprite_sheet()
	if !testing.expectf(t, result.err == .None, "the shipped drudge sheet must load, got %v", result.err) do return
	defer destroy_sprite_sheet(sheet)

	testing.expectf(
		t,
		sheet.width == DRUDGE_SPRITE_FRAME_W * DRUDGE_SPRITE_COLUMNS && sheet.height == DRUDGE_SPRITE_FRAME_H * DRUDGE_SPRITE_ROWS,
		"the sheet must be %dx%d, got %dx%d",
		DRUDGE_SPRITE_FRAME_W * DRUDGE_SPRITE_COLUMNS,
		DRUDGE_SPRITE_FRAME_H * DRUDGE_SPRITE_ROWS,
		sheet.width,
		sheet.height,
	)
}

@(test)
test_every_declared_drudge_frame_holds_ink_and_every_undeclared_frame_is_empty :: proc(t: ^testing.T) {
	sheet, result := load_drudge_sprite_sheet()
	if !testing.expectf(t, result.err == .None, "the shipped drudge sheet must load, got %v", result.err) do return
	defer destroy_sprite_sheet(sheet)

	for motion in Drudge_Motion {
		declared := DRUDGE_SPRITE_ROW_FRAMES[motion]
		for column in 0 ..< DRUDGE_SPRITE_COLUMNS {
			ink := 0
			for y in i32(0) ..< DRUDGE_SPRITE_FRAME_H {
				for x in i32(0) ..< DRUDGE_SPRITE_FRAME_W {
					if drudge_sprite_pixel(sheet, motion, column, 1, x, y).a != 0 do ink += 1
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
test_the_drudge_body_box_is_centred_in_the_frame_and_stays_inside_it :: proc(t: ^testing.T) {
	testing.expect(
		t,
		DRUDGE_SPRITE_BODY_X >= 0 && DRUDGE_SPRITE_BODY_X + DRUDGE_SPRITE_BODY_W <= DRUDGE_SPRITE_FRAME_W,
		"the body box must fit inside the frame across",
	)
	testing.expect(
		t,
		DRUDGE_SPRITE_BODY_Y >= 0 && DRUDGE_SPRITE_BODY_Y + DRUDGE_SPRITE_BODY_H <= DRUDGE_SPRITE_FRAME_H,
		"the body box must fit inside the frame down",
	)
	testing.expectf(
		t,
		2 * DRUDGE_SPRITE_BODY_X + DRUDGE_SPRITE_BODY_W == DRUDGE_SPRITE_FRAME_W,
		"the body box must be centred across the frame, or mirroring reads as a different drudge",
	)
}

@(test)
test_drudge_sprite_frame_never_returns_a_column_the_row_does_not_declare :: proc(t: ^testing.T) {
	for motion in Drudge_Motion {
		declared := DRUDGE_SPRITE_ROW_FRAMES[motion]
		anim := f32(0)
		for anim < 500 {
			column := drudge_sprite_frame(motion, anim)
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
test_loading_a_missing_drudge_sprite_sheet_fails_cleanly :: proc(t: ^testing.T) {
	sheet, result := load_sprite_sheet(
		"data/sprites/no_such_drudge.png",
		DRUDGE_SPRITE_FRAME_W, DRUDGE_SPRITE_FRAME_H, DRUDGE_SPRITE_COLUMNS, DRUDGE_SPRITE_ROWS,
	)
	defer destroy_sprite_sheet(sheet)

	testing.expect(t, result.err == .File_Unreadable)
	testing.expect(t, sheet.pixels == nil, "a failed load must not hand back pixels")
}

@(test)
test_a_left_facing_drudge_frame_is_the_right_facing_frame_read_back_to_front :: proc(t: ^testing.T) {
	sheet, result := load_drudge_sprite_sheet()
	if !testing.expectf(t, result.err == .None, "the shipped drudge sheet must load, got %v", result.err) do return
	defer destroy_sprite_sheet(sheet)

	for y in i32(0) ..< DRUDGE_SPRITE_FRAME_H {
		for x in i32(0) ..< DRUDGE_SPRITE_FRAME_W {
			right := drudge_sprite_pixel(sheet, .Idle, 0, 1, x, y)
			left := drudge_sprite_pixel(sheet, .Idle, 0, -1, DRUDGE_SPRITE_FRAME_W - 1 - x, y)
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
