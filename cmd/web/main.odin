package main

// The game in a browser.
//
// The page loads a WebAssembly module and calls it once a frame. That
// is the whole difference from the desktop: `app_start` and `app_frame`
// are the same procedures `bin/the-game` runs, in the same package.
//
// The frame is handed to emscripten rather than driven from a loop of
// our own, because a page that never returns to the browser never draws
// and never reads a touch. See docs/web.md.

import "base:runtime"
import game "../../src"

foreign import emscripten "env.o"

// The temporary allocator is emptied at the end of every frame, so it
// only ever holds one frame of strings and paths.
TEMP_ARENA_SIZE :: 4 * 1024 * 1024

Main_Loop :: #type proc "c" ()

@(default_calling_convention = "c")
foreign emscripten {
	emscripten_set_main_loop :: proc(f: Main_Loop, fps: i32, simulate_infinite_loop: i32) ---
	emscripten_run_script :: proc(script: cstring) ---
	emscripten_cancel_main_loop :: proc() ---
}

// The page calls back with no context, so the one the module started
// with is kept here and put back on every frame.
@(private = "file") ctx: runtime.Context
@(private = "file") temp: runtime.Arena
@(private = "file") app: game.App
@(private = "file") run: game.Run

// The page starts the module at `main`, which is entry.c, which calls
// this. Odin's own WebAssembly entry point is not built into an object
// file, so the boot is one exported procedure instead -- and it has to
// do what that entry point does: start the runtime. Until it runs there
// is no temporary allocator and no `@(init)` procedure has run, so the
// first file the game asks for comes back with a null name.
@(export)
game_boot :: proc "c" () {
	context = runtime.default_context()
	context.allocator = heap_allocator()
	_ = runtime.arena_init(&temp, TEMP_ARENA_SIZE, context.allocator)
	context.temp_allocator = runtime.arena_allocator(&temp)

	// The runtime is started by hand, because an object file has no
	// `_start` to start it: until this runs, no `@(init)` procedure has
	// run and the light tables the world is drawn with are empty.
	runtime._startup_runtime()
	ctx = context

	if !game.app_start(&app, &run, {}) {
		return
	}
	// The world is loaded and the first frame is next, which is when
	// the page may take its front down. See web/shell.html.
	emscripten_run_script("if (window.game_ready) game_ready()")

	emscripten_set_main_loop(frame, 0, 0)
}

@(private = "file")
@(export)
frame :: proc "c" () {
	context = ctx
	if game.app_frame(&app, &run) {
		game.app_stop(&app)
		emscripten_cancel_main_loop()
	}
}
