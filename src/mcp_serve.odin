#+build !freestanding
package game

// The server loop: a request a line on stdin, a reply a line on stdout.
//
// It is the one part of the MCP server that is not the game. A browser
// has no stdin and no stdout, and `core:os` does not build for it, so
// the loop lives in its own file and the browser build leaves it out.
// Everything the loop calls -- mcp_handle and every tool under it --
// is in the package proper and builds everywhere.
//
// See docs/web.md, "What the web cannot have".

import "core:bufio"
import "core:os"
import "core:strings"

mcp_serve :: proc(s: ^Sim) {
	reader: bufio.Reader
	bufio.reader_init(&reader, os.to_stream(os.stdin), 64 * 1024)
	defer bufio.reader_destroy(&reader)

	for {
		line, err := bufio.reader_read_string(&reader, '\n', context.allocator)
		if err != nil do break
		defer delete(line)

		text := strings.trim_space(line)
		if len(text) > 0 {
			out := strings.builder_make(context.temp_allocator)
			mcp_handle(s, text, &out)
			if strings.builder_len(out) > 0 {
				_, _ = os.write_string(os.stdout, strings.to_string(out))
			}
		}
		free_all(context.temp_allocator)
	}
}
