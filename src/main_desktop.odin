#+build !freestanding
package game

// The desktop game: the arguments, the window, and the loop that calls
// `app_frame` until the window closes.
//
// The browser has no arguments and may not sit in a loop of its own, so
// it has its own small entry in `cmd/web` and calls the same frame.
// Everything both of them use is in `main.odin`.
//
// See docs/web.md, "What the web cannot have".

import "core:os"
import rl "vendor:raylib"

main :: proc() {
	run: Run
	app: App
	if !app_start(&app, &run, os.args[1:]) do os.exit(1)
	defer app_stop(&app)

	for !rl.WindowShouldClose() {
		if app_frame(&app, &run) do break
	}
}
