package game

import "core:os"
import "core:strconv"
import "core:strings"
import "core:testing"

// The reel.
//
// The README's animations are the game being played, and a hand on the
// keys cannot play the same thing twice. A reel is the play written
// down: a script of timed inputs the window runs one tick a frame,
// exactly as a player's keys would arrive, while every drawn frame is
// written to a directory for ffmpeg to fold into a video.
//
//     ./bin/the-game script=docs/reel.txt record=shots/reel
//
// The script is lines of `<ticks> <words>`:
//
//     180 wait                 stand still
//     240 walk                 hold right (walk left for the other way)
//     120 run jump             hold shift, tap jump as the segment starts
//     150 fly                  hold jump, so the jetpack lights
//     90  dig aim=120          hold dig, aimed 120 degrees clockwise of east
//     600 skip                 run the world forward and record nothing
//
// `skip` is the cut: the world runs on -- ticks, physics, the lot --
// but no frames are written, so one deterministic run can carry a
// whole tour with the dull walking left out. A `#` starts a comment.
//
// The reel drives sim_step_player with the same arguments the keys
// would, so nothing it records is staged: if the reel can dig to the
// pond, so can a hand.

Reel_Segment :: struct {
	ticks:     int,
	held:      Player_Input,
	aim:       u8,
	tap_jump:  bool,
	tap_throw: bool,
	skip:      bool,
}

Reel :: struct {
	segments: [dynamic]Reel_Segment,
	dir:      string,
	every:    int, // record every Nth frame; 2 films at 60 and plays at 30

	at:    int,
	tick:  int,
	shown: int, // frames that reached the screen, for the every-Nth gate
	wrote: int, // frames written to the directory
	on:    bool,
}

reel_load :: proc(path: string, allocator := context.allocator) -> (reel: Reel, ok: bool) {
	data, err := os.read_entire_file(path, allocator)
	if err != nil do return {}, false
	defer delete(data, allocator)

	reel.segments = make([dynamic]Reel_Segment, allocator)
	reel.every = 2

	text := string(data)
	for raw_line in strings.split_lines_iterator(&text) {
		line := strings.trim_space(raw_line)
		if idx := strings.index_byte(line, '#'); idx >= 0 {
			line = strings.trim_space(line[:idx])
		}
		if len(line) == 0 do continue

		seg, seg_ok := reel_parse_segment(line)
		if !seg_ok {
			delete(reel.segments)
			return {}, false
		}
		append(&reel.segments, seg)
	}

	if len(reel.segments) == 0 {
		delete(reel.segments)
		return {}, false
	}
	reel.on = true
	return reel, true
}

reel_parse_segment :: proc(line: string) -> (seg: Reel_Segment, ok: bool) {
	rest := line
	first, first_ok := strings.fields_iterator(&rest)
	if !first_ok do return {}, false

	ticks, ticks_ok := strconv.parse_int(first)
	if !ticks_ok || ticks < 1 do return {}, false
	seg.ticks = ticks

	// Right is the default because the village reads west to east; a
	// segment says `left` when it means it.
	going_left := false
	moving := false

	for {
		word, word_ok := strings.fields_iterator(&rest)
		if !word_ok do break

		switch {
		case word == "wait":
		case word == "skip":
			seg.skip = true
		case word == "walk":
			moving = true
		case word == "run":
			moving = true
			seg.held += {.Run}
		case word == "left":
			going_left = true
		case word == "right":
			going_left = false
		case word == "jump":
			seg.tap_jump = true
		case word == "fly":
			seg.held += {.Jump}
			seg.tap_jump = true
		case word == "dig":
			seg.held += {.Dig}
		case word == "throw":
			seg.tap_throw = true
		case strings.has_prefix(word, "aim="):
			degrees, aim_ok := strconv.parse_int(word[4:])
			if !aim_ok do return {}, false
			seg.aim = u8((degrees * 256 / 360) & 255)
		case:
			return {}, false
		}
	}

	if moving do seg.held += going_left ? {.Left} : {.Right}
	return seg, true
}

reel_done :: proc(reel: Reel) -> bool {
	return reel.at >= len(reel.segments)
}

// One tick of the reel, run through the same procedures a frame of
// play runs. A skip segment is consumed whole -- the world runs
// forward tick by tick with nothing drawn between -- so the frame this
// returns into always has something worth showing. `record` says
// whether the frame about to be drawn belongs in the film.
reel_step :: proc(reel: ^Reel, app: ^App) -> (record: bool) {
	for reel.at < len(reel.segments) && reel.segments[reel.at].skip {
		seg := reel.segments[reel.at]
		for reel.tick < seg.ticks {
			// The first tick of a skip segment taps its keys exactly as
			// a shown segment's does. Dropping the tap here left every
			// skipped jump on the ground: a cut in the film must not be
			// a cut in the playing.
			reel_tick(app, seg, first = reel.tick == 0)
			reel.tick += 1
		}
		reel.at += 1
		reel.tick = 0
	}
	if reel.at >= len(reel.segments) do return false

	seg := reel.segments[reel.at]
	reel_tick(app, seg, first = reel.tick == 0)

	reel.tick += 1
	if reel.tick >= seg.ticks {
		reel.at += 1
		reel.tick = 0
	}
	return true
}

@(private = "file")
reel_tick :: proc(app: ^App, seg: Reel_Segment, first := false) {
	held := seg.held
	if first && seg.tap_throw do held += {.Throw}

	sim_step_player(&app.sim, held, first && seg.tap_jump, seg.aim)
	sandbox_step(&app.sandbox, app.world.materials)
}

@(test)
test_a_reel_line_reads_as_the_keys_it_stands_for :: proc(t: ^testing.T) {
	seg, ok := reel_parse_segment("120 run jump")
	testing.expect(t, ok, "a plain line must parse")
	testing.expect(t, seg.ticks == 120)
	testing.expect(t, seg.held == {.Run, .Right}, "run is a hurry to the right unless told left")
	testing.expect(t, seg.tap_jump, "jump is a tap as the segment starts")
	testing.expect(t, !seg.skip)

	seg, ok = reel_parse_segment("90 dig aim=120")
	testing.expect(t, ok)
	testing.expect(t, .Dig in seg.held, "dig is held for the whole segment")
	testing.expectf(t, seg.aim == 85, "120 degrees is 85 of 256, got %d", seg.aim)
	testing.expect(t, seg.held & {.Left, .Right} == {}, "digging on the spot walks nowhere")

	seg, ok = reel_parse_segment("60 walk left")
	testing.expect(t, ok)
	testing.expect(t, seg.held == {.Left})

	seg, ok = reel_parse_segment("600 skip")
	testing.expect(t, ok)
	testing.expect(t, seg.skip, "a skip runs the world and records nothing")

	seg, ok = reel_parse_segment("45 fly")
	testing.expect(t, ok)
	testing.expect(t, .Jump in seg.held, "flying holds the jump key down")
	testing.expect(t, seg.tap_jump, "and taps it first, to leave the ground")

	_, ok = reel_parse_segment("banana walk")
	testing.expect(t, !ok, "a line that does not start with ticks is refused")
	_, ok = reel_parse_segment("60 moonwalk")
	testing.expect(t, !ok, "an unknown word is refused, not skipped")
}

@(test)
test_a_reel_runs_its_segments_in_order_and_ends :: proc(t: ^testing.T) {
	path := "reel_test.tmp.txt"
	body := "# a comment\n3 wait\n4 skip\n2 walk\n"
	if !testing.expect(t, os.write_entire_file(path, transmute([]byte)body) == nil, "the script must write") do return
	defer os.remove(path)

	reel, ok := reel_load(path)
	if !testing.expect(t, ok, "the script must load") do return
	defer delete(reel.segments)

	testing.expect(t, len(reel.segments) == 3, "three lines are three segments")
	testing.expect(t, reel.segments[1].skip)

	s: Sim
	if !testing.expect(t, sim_load(&s) == .None, "the world must load") do return
	sim_play_begin(&s)

	// The app owns the sim from here: `using sim` shares the buffers,
	// so the one unload goes through the copy that was stepped.
	app := App{sim = s}
	defer sim_unload(&app.sim)

	recorded := 0
	for !reel_done(reel) {
		if reel_step(&reel, &app) do recorded += 1
	}

	testing.expect(t, recorded == 5, "the wait and the walk are on film and the skip is not")
}
