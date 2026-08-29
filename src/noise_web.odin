#+build freestanding
package game

// Where the talk goes in a browser: the console of the page, through
// raylib's own log, because `core:os` does not build for WebAssembly
// and a page has no stdout, no stderr and no environment.
//
// See docs/web.md, "What the web cannot have".

import "core:fmt"
import rl "vendor:raylib"

noise_env :: proc() -> (text: string, found: bool) {
	return "", false
}

noise_talk :: proc(text: string) {
	rl.TraceLog(.WARNING, "%s", fmt.ctprintf("%s", text))
}

noise_result :: proc(text: string) {
	rl.TraceLog(.INFO, "%s", fmt.ctprintf("%s", text))
}
