#+build !freestanding
package game

// Where the talk goes on a machine with a shell: the result to stdout,
// everything else to stderr, and the rung out of the environment.
//
// The browser has none of the three, and answers the same three calls
// its own way in src/noise_web.odin. See docs/web.md, "What the web
// cannot have".

import "core:fmt"
import "core:os"

noise_env :: proc() -> (text: string, found: bool) {
	return os.lookup_env(NOISE_ENV, context.allocator)
}

noise_talk :: proc(text: string) {
	fmt.eprintln(text)
}

noise_result :: proc(text: string) {
	fmt.println(text)
}
