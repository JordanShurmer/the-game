package game

// The controls for a screen with no keys.
//
// A phone gives the game a list of points that are being touched, and
// nothing else. This file turns that list into the same `Player_Input`
// the keys make, so nothing under it knows which one moved the wizard.
//
// The layout is a thumb pad on the left and three buttons on the right,
// the way a hand holds a phone: the left thumb walks, the right thumb
// works. The pad also aims, because a wizard who digs and throws needs
// a direction and there is no cursor to take one from.
//
// `touch_read` is a procedure of the points and the size of the screen
// and nothing else, which is what the tests measure.
//
// See docs/web.md, "The touch controls".

import "core:math"
import testing "check"
import rl "vendor:raylib"

// The pad walks at a touch and runs at a push: past this share of its
// radius the wizard runs. Under the dead zone he stands still, so a
// thumb resting on the glass is not a step.
TOUCH_PAD_DEAD :: 0.22
TOUCH_PAD_RUN  :: 0.72

// A phone is held in two hands and the thumbs reach the corners, so
// every control is placed from the corner it belongs to and measured in
// shares of the SHORTER side of the screen. A thumb is the same size on
// a wide screen and a tall one, and a share of the width alone walks
// the pad off the edge of a screen held upright.
TOUCH_PAD_X      :: 0.24 // from the left
TOUCH_PAD_Y      :: 0.24 // up from the bottom
TOUCH_PAD_RADIUS :: 0.20

Touch_Button :: struct {
	button: Player_Button,
	x, y:   f32, // in from the right, and up from the bottom
	radius: f32,
	label:  cstring,
}

TOUCH_BUTTONS :: [?]Touch_Button {
	{.Jump,  0.16, 0.16, 0.115, "JUMP"},
	{.Dig,   0.42, 0.13, 0.095, "DIG"},
	{.Throw, 0.15, 0.45, 0.095, "THROW"},
}

// Where a control sits on a screen of this size, in pixels.
Touch_Circle :: struct {
	x, y, radius: f32,
}

touch_pad_circle :: proc(w, h: f32) -> Touch_Circle {
	side := min(w, h)
	return {x = side * TOUCH_PAD_X, y = h - side * TOUCH_PAD_Y, radius = side * TOUCH_PAD_RADIUS}
}

touch_button_circle :: proc(b: Touch_Button, w, h: f32) -> Touch_Circle {
	side := min(w, h)
	return {x = w - side * b.x, y = h - side * b.y, radius = side * b.radius}
}

@(private = "file")
touch_inside :: proc(c: Touch_Circle, x, y: f32) -> bool {
	dx, dy := x - c.x, y - c.y
	return dx * dx + dy * dy <= c.radius * c.radius
}

// What the screen is asking for. `aim_set` is false where no thumb is
// on the pad, and the caller then leaves the aim it had.
Touch_Read :: struct {
	held:    Player_Input,
	aim:     u8,
	aim_set: bool,
}

touch_read :: proc(points: []rl.Vector2, w, h: f32) -> (read: Touch_Read) {
	pad := touch_pad_circle(w, h)
	buttons := TOUCH_BUTTONS

	for p in points {
		for b in buttons {
			if touch_inside(touch_button_circle(b, w, h), p.x, p.y) {
				read.held += {b.button}
			}
		}

		if !touch_inside(pad, p.x, p.y) do continue

		dx, dy := p.x - pad.x, p.y - pad.y
		reach := math.sqrt(dx * dx + dy * dy) / pad.radius
		if reach < TOUCH_PAD_DEAD do continue

		read.aim = player_aim_of(dx, dy)
		read.aim_set = true

		// A thumb straight up or straight down is a direction to dig
		// in, not a step, so the walk takes the side of the pad the
		// thumb is on and not the sign of a hair of it.
		if abs(dx) > pad.radius * TOUCH_PAD_DEAD {
			read.held += dx < 0 ? {Player_Button.Left} : {Player_Button.Right}
			if reach >= TOUCH_PAD_RUN do read.held += {.Run}
		}
	}
	return read
}

// What the game holds from one frame to the next: the buttons the last
// frame was already holding, which is how a jump knows it is new, and
// whether this screen has ever been touched, which is what puts the
// controls on it. A desktop browser never draws them.
Touch :: struct {
	held: Player_Input,
	seen: bool,
}

// The points raylib reports, in the caller's allocator.
touch_points :: proc(allocator := context.temp_allocator) -> []rl.Vector2 {
	count := int(rl.GetTouchPointCount())
	points := make([]rl.Vector2, count, allocator)
	for i in 0 ..< count {
		points[i] = rl.GetTouchPosition(i32(i))
	}
	return points
}

touch_step :: proc(t: ^Touch, w, h: f32) -> (read: Touch_Read, pressed: Player_Input) {
	points := touch_points()
	read = touch_read(points, w, h)
	if len(points) > 0 do t.seen = true

	pressed = read.held &~ t.held
	t.held = read.held
	return read, pressed
}

TOUCH_FACE    :: rl.Color{236, 245, 255, 40}
TOUCH_EDGE    :: rl.Color{236, 245, 255, 90}
TOUCH_PRESSED :: rl.Color{140, 210, 255, 110}

touch_draw :: proc(t: Touch, w, h: f32) {
	if !t.seen do return

	pad := touch_pad_circle(w, h)
	rl.DrawCircleLinesV({pad.x, pad.y}, pad.radius, TOUCH_EDGE)
	rl.DrawCircleV({pad.x, pad.y}, pad.radius * TOUCH_PAD_DEAD, TOUCH_FACE)

	buttons := TOUCH_BUTTONS
	for b in buttons {
		c := touch_button_circle(b, w, h)
		down := b.button in t.held
		rl.DrawCircleV({c.x, c.y}, c.radius, down ? TOUCH_PRESSED : TOUCH_FACE)
		rl.DrawCircleLinesV({c.x, c.y}, c.radius, TOUCH_EDGE)

		size := i32(c.radius * 0.42)
		width := rl.MeasureText(b.label, size)
		rl.DrawText(b.label, i32(c.x) - width / 2, i32(c.y) - size / 2, size, TOUCH_EDGE)
	}
}

// ------------------------------------------------------------- the tests

@(test)
test_a_thumb_on_the_left_of_the_pad_walks_left :: proc(t: ^testing.T) {
	pad := touch_pad_circle(1280, 720)
	read := touch_read({{pad.x - pad.radius * 0.5, pad.y}}, 1280, 720)

	testing.expect(t, .Left in read.held, "the left of the pad must walk left")
	testing.expect(t, .Right not_in read.held, "and not right at the same time")
	testing.expect(t, .Run not_in read.held, "half way out is a walk")
	testing.expect(t, read.aim_set, "the pad aims")
	testing.expect_value(t, read.aim, PLAYER_AIM_LEFT)
}

@(test)
test_a_thumb_pushed_to_the_rim_runs :: proc(t: ^testing.T) {
	pad := touch_pad_circle(1280, 720)
	read := touch_read({{pad.x + pad.radius * 0.95, pad.y}}, 1280, 720)

	testing.expect(t, .Right in read.held, "the right of the pad must walk right")
	testing.expect(t, .Run in read.held, "and the rim of it must run")
}

@(test)
test_a_thumb_resting_in_the_middle_of_the_pad_stands_still :: proc(t: ^testing.T) {
	pad := touch_pad_circle(1280, 720)
	read := touch_read({{pad.x + pad.radius * 0.1, pad.y}}, 1280, 720)

	testing.expect_value(t, read.held, Player_Input{})
	testing.expect(t, !read.aim_set, "a thumb inside the dead zone aims at nothing")
}

// Straight up is where he digs when he wants a shaft over his head, and
// a hair of sideways in it must not walk him out from under it.
@(test)
test_a_thumb_at_the_top_of_the_pad_aims_up_and_does_not_walk :: proc(t: ^testing.T) {
	pad := touch_pad_circle(1280, 720)
	read := touch_read({{pad.x, pad.y - pad.radius * 0.9}}, 1280, 720)

	testing.expect_value(t, read.aim, PLAYER_AIM_UP)
	testing.expect(t, .Left not_in read.held && .Right not_in read.held, "straight up is not a step")
}

@(test)
test_each_button_answers_its_own_circle :: proc(t: ^testing.T) {
	buttons := TOUCH_BUTTONS
	for b in buttons {
		c := touch_button_circle(b, 1280, 720)
		read := touch_read({{c.x, c.y}}, 1280, 720)
		testing.expectf(t, b.button in read.held, "the %v button must answer its own middle", b.button)
		testing.expectf(t, card(read.held) == 1, "and nothing else: %v", read.held)
	}
}

@(test)
test_no_two_controls_lie_on_each_other :: proc(t: ^testing.T) {
	// A thumb is about 40 pixels wide on the screen the game draws, so
	// two controls that touch are two a thumb cannot tell apart.
	circles := make([dynamic]Touch_Circle, context.temp_allocator)
	append(&circles, touch_pad_circle(1280, 720))
	buttons := TOUCH_BUTTONS
	for b in buttons do append(&circles, touch_button_circle(b, 1280, 720))

	for a, i in circles {
		for b, j in circles {
			if j <= i do continue
			dx, dy := a.x - b.x, a.y - b.y
			apart := math.sqrt(dx * dx + dy * dy)
			testing.expectf(
				t, apart > a.radius + b.radius,
				"two controls overlap: %.0f apart, and %.0f of radius between them",
				apart, a.radius + b.radius,
			)
		}
	}
	free_all(context.temp_allocator)
}

@(test)
test_every_control_stands_on_the_screen :: proc(t: ^testing.T) {
	for size in ([?][2]f32{{1280, 720}, {854, 480}, {720, 1280}}) {
		w, h := size.x, size.y
		circles := make([dynamic]Touch_Circle, context.temp_allocator)
		append(&circles, touch_pad_circle(w, h))
		buttons := TOUCH_BUTTONS
		for b in buttons do append(&circles, touch_button_circle(b, w, h))

		for c in circles {
			testing.expectf(
				t,
				c.x - c.radius >= 0 && c.x + c.radius <= w &&
				c.y - c.radius >= 0 && c.y + c.radius <= h,
				"a control at %.0f,%.0f r%.0f falls off a %.0fx%.0f screen",
				c.x, c.y, c.radius, w, h,
			)
		}
		free_all(context.temp_allocator)
	}
}

@(test)
test_a_new_button_is_pressed_once :: proc(t: ^testing.T) {
	touch: Touch
	touch.held = {.Left}

	read := Touch_Read{held = {.Left, .Jump}}
	pressed := read.held &~ touch.held
	testing.expect_value(t, pressed, Player_Input{.Jump})
}
