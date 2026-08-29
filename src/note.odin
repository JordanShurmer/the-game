package game

// What the game says when something it needed did not arrive: a
// material file that will not parse, a shader that will not compile, a
// sprite sheet that is not there.
//
// It goes through raylib's log rather than through `core:fmt`'s
// printers, because those reach `core:os` and the browser build has no
// `core:os`. In a terminal the line lands on stderr the way it always
// did. In a browser it lands in the console of the page.
//
// See docs/web.md, "What the web cannot have".

import "core:fmt"
import rl "vendor:raylib"

note :: proc(format: string, args: ..any) {
	rl.TraceLog(.WARNING, "%s", fmt.ctprintf(format, ..args))
}
