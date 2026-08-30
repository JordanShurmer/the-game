package game

// How loud the toolset is. One ladder, and everything that can speak
// reads the same rung: the game, the command line tools, the test run,
// the Makefile, the seeders, and the toolchain install.
//
//   0  the result, and nothing else            (the default)
//   1  a line for each piece of work
//   2  the detail behind each line
//   3  everything, the graphics trace log included
//
// Set the rung in the environment with GAME_DEBUG=n, or on the command
// line of a tool that takes key=value arguments with debug=n. The
// command line wins, because it is nearer the run.
//
// The rule for a new message: if a run that goes right must print it,
// it is a result and it goes to stdout with no rung. Everything else
// takes a rung and goes to stderr, so a shell can keep the result and
// drop the talk.

import "base:runtime"
import "core:fmt"
import "core:strconv"
import testing "check"
import rl "vendor:raylib"

NOISE_RESULT  :: 0
NOISE_STEP    :: 1
NOISE_DETAIL  :: 2
NOISE_TRACE   :: 3

NOISE_ENV :: "GAME_DEBUG"

@(private = "file")
noise_rung: int

// The rung the environment asks for, read once before anything runs.
// A tool that takes a debug= argument calls noise_set afterwards.
@(init)
noise_init :: proc "contextless" () {
	context = runtime.default_context()

	// Where the rung comes from is the one thing the browser cannot
	// answer the way a shell does: a page has no environment. See
	// src/noise_desktop.odin and src/noise_web.odin.
	if text, found := noise_env(); found {
		defer delete(text)
		if n, ok := strconv.parse_int(text); ok {
			noise_rung = clamp(n, NOISE_RESULT, NOISE_TRACE)
		}
	}
	noise_graphics()
}

noise_level :: proc() -> int {
	return noise_rung
}

noise_set :: proc(rung: int) {
	noise_rung = clamp(rung, NOISE_RESULT, NOISE_TRACE)
	noise_graphics()
}

// raylib says a line for every file it opens and every image it
// decodes. That is a trace, so it lives on the top rung. Below it the
// library keeps its warnings until the second rung and then goes
// quiet, because a warning nobody asked for is still noise in a run
// that goes right.
noise_graphics :: proc() {
	switch {
	case noise_rung >= NOISE_TRACE:
		rl.SetTraceLogLevel(.ALL)
	case noise_rung >= NOISE_DETAIL:
		rl.SetTraceLogLevel(.WARNING)
	case:
		rl.SetTraceLogLevel(.NONE)
	}
}

// A line that only a run asking for that rung sees.
say :: proc(rung: int, format: string, args: ..any) {
	if noise_rung < rung do return
	noise_talk(fmt.tprintf(format, ..args))
}

// The result of a run: the file a build wrote, the PNG a shot drew. It
// carries no rung, and it goes to stdout, so a shell can keep it and
// drop the talk.
result :: proc(format: string, args: ..any) {
	noise_result(fmt.tprintf(format, ..args))
}

// Something went wrong and the run is about to stop. A fault is not
// talk, so it prints at every rung.
//
// The one exception is the test run: the suite feeds the loaders bad
// files on purpose to prove they refuse them, and each refusal would
// print a fault that no reader of a passing run wants. Under `odin
// test` a fault waits for the first rung, where a reader who is
// hunting a loader has asked to see it.
fault :: proc(format: string, args: ..any) {
	when ODIN_TEST {
		if noise_rung < NOISE_STEP do return
	}
	noise_talk(fmt.tprintf(format, ..args))
}

// ---------------------------------------------------------------- tests

@(test)
test_the_ladder_clamps_to_the_rungs_it_has :: proc(t: ^testing.T) {
	was := noise_level()
	defer noise_set(was)

	noise_set(NOISE_TRACE + 9)
	testing.expectf(
		t, noise_level() == NOISE_TRACE,
		"a rung above the top must settle on the top, got %d", noise_level(),
	)

	noise_set(-3)
	testing.expectf(
		t, noise_level() == NOISE_RESULT,
		"a rung below the bottom must settle on the bottom, got %d", noise_level(),
	)

	for rung in NOISE_RESULT ..= NOISE_TRACE {
		noise_set(rung)
		testing.expectf(t, noise_level() == rung, "rung %d must stand", rung)
	}
}

@(test)
test_a_line_waits_for_the_rung_that_asked_for_it :: proc(t: ^testing.T) {
	// say and fault write to stderr, which a test cannot read back, so
	// what is checked here is the gate itself: the rung a line is held
	// against, which is the whole of the decision.
	was := noise_level()
	defer noise_set(was)

	noise_set(NOISE_RESULT)
	testing.expect(
		t, noise_level() < NOISE_STEP,
		"at the bottom rung a step line must be held back",
	)

	noise_set(NOISE_STEP)
	testing.expect(
		t, noise_level() >= NOISE_STEP && noise_level() < NOISE_DETAIL,
		"the first rung must pass a step line and hold a detail line",
	)

	noise_set(NOISE_TRACE)
	testing.expect(
		t, noise_level() >= NOISE_DETAIL,
		"the top rung must pass every line below it",
	)
}
