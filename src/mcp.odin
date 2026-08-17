package game

import "core:bufio"
import "core:encoding/json"
import "core:os"
import "core:strings"
import "core:testing"
import rl "vendor:raylib"

/*
MCP server.

The server speaks JSON-RPC 2.0 over standard input and standard
output. One message fills one line. Standard output carries only
protocol messages; a note for a person goes to standard error.

The server holds one Sim. Every tool works on that one world.

The queue is the reason this server works well for a slow client.
A model takes seconds to decide on a move, but the command it
sends carries a tick, not a time. The world runs only when the
client asks it to run, and a command lands on the tick that the
queue promised. So the world of a slow client and the world of a
fast client come out the same.
*/

MCP_SERVER_NAME    :: "the-game"
MCP_SERVER_VERSION :: "0.1.0"
MCP_PROTOCOL       :: "2025-06-18"

MCP_INSTRUCTIONS :: `You author and run a Noita-like world. There are three parts.

THE BIOME MAP says which biome owns which region. One map pixel is one square
region of the world. Read it with biome_map_view, paint it with
biome_map_paint, write it with biome_map_save. A save is blocked while the
painted map falls into more than one connected piece, because a world the
player cannot walk across is a mistake.

TILES say what a region is made of. A biome with "generator = tile" repeats one
64x64 authored tile through every region it owns. Open one with tile_open, read
it with tile_view, paint it with tile_paint, write it with tile_save. Painting
one tile changes every region of that biome at once.

THE SANDBOX runs the physics. sandbox_open fills a rectangle of the authored
world with cells and starts a run; call it again with no arguments after an
edit to bring that edit into the physics. Nothing happens the moment you send a
command: enqueue_input gives each command an execution tick and the queue holds
it until then. Call tick to run the world forward, and observe to read it back.

Both editors call the same procedures the mouse calls in the game window, so
what you paint is what a player would paint.

The sandbox is deterministic. The same seed, the same region, and the same
commands always give the same checksum, so a run repeats exactly.

The y axis points down. Painting uses the glyphs that list_materials and
list_biomes print.`

// ------------------------------------------------------------
// Transport
// ------------------------------------------------------------

/*
Stop the graphics library writing to standard output.

Its image loader reports every file it reads, and it reports on
standard output, which is the wire this server talks on. One stray
line would break the stream. The server calls this before it loads
anything, so no PNG can corrupt the protocol.
*/
mcp_silence_graphics_log :: proc() {
	rl.SetTraceLogLevel(.NONE)
}

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
			// The reply is built whole and then sent in one write.
			// A notification builds nothing, and nothing is sent.
			out := strings.builder_make(context.temp_allocator)
			mcp_handle(s, text, &out)
			if strings.builder_len(out) > 0 {
				_, _ = os.write_string(os.stdout, strings.to_string(out))
			}
		}
		free_all(context.temp_allocator)
	}
}

mcp_handle :: proc(s: ^Sim, text: string, out: ^strings.Builder) {
	value, parse_err := json.parse_string(text, .JSON, true, context.temp_allocator)
	if parse_err != .None {
		mcp_write_error(out, nil, -32700, "the message is not valid JSON")
		return
	}

	request, is_object := value.(json.Object)
	if !is_object {
		mcp_write_error(out, nil, -32600, "the message must be a JSON object")
		return
	}

	// A message without an id is a notification. It never gets a reply.
	id, has_id := request["id"]
	if !has_id do return

	method := json_string_field(request, "method", "")

	switch method {
	case "initialize":
		mcp_write_result(out, id, mcp_initialize_result(request))
	case "ping":
		mcp_write_result(out, id, "{}")
	case "tools/list":
		mcp_write_result(out, id, MCP_TOOLS_JSON)
	case "tools/call":
		mcp_call_tool(s, out, id, request)
	case:
		mcp_write_error(out, id, -32601, "unknown method")
	}
}

mcp_initialize_result :: proc(request: json.Object) -> string {
	version := MCP_PROTOCOL
	if params, ok := json_object_field(request, "params"); ok {
		// Answer with the version that the client asked for when this
		// server knows it. Otherwise answer with the newest one.
		switch asked := json_string_field(params, "protocolVersion", ""); asked {
		case "2024-11-05", "2025-03-26", "2025-06-18":
			version = asked
		}
	}

	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `{"protocolVersion":`)
	json_write_string(&b, version)
	strings.write_string(&b, `,"capabilities":{"tools":{"listChanged":false}}`)
	strings.write_string(&b, `,"serverInfo":{"name":`)
	json_write_string(&b, MCP_SERVER_NAME)
	strings.write_string(&b, `,"version":`)
	json_write_string(&b, MCP_SERVER_VERSION)
	strings.write_string(&b, `},"instructions":`)
	json_write_string(&b, MCP_INSTRUCTIONS)
	strings.write_string(&b, "}")
	return strings.to_string(b)
}

// ------------------------------------------------------------
// Replies
// ------------------------------------------------------------

mcp_write_result :: proc(out: ^strings.Builder, id: json.Value, result: string) {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `{"jsonrpc":"2.0","id":`)
	json_write_id(&b, id)
	strings.write_string(&b, `,"result":`)
	strings.write_string(&b, result)
	strings.write_string(&b, "}")
	mcp_write_line(out, strings.to_string(b))
}

mcp_write_error :: proc(out: ^strings.Builder, id: json.Value, code: int, message: string) {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `{"jsonrpc":"2.0","id":`)
	json_write_id(&b, id)
	strings.write_string(&b, `,"error":{"code":`)
	strings.write_int(&b, code)
	strings.write_string(&b, `,"message":`)
	json_write_string(&b, message)
	strings.write_string(&b, "}}")
	mcp_write_line(out, strings.to_string(b))
}

/*
Reply to a tool call.

A tool that fails still sends a result, with isError set. The
client shows the text to the model, which can then correct itself.
A JSON-RPC error means the call itself was malformed.
*/
mcp_write_tool_text :: proc(out: ^strings.Builder, id: json.Value, text: string, is_error := false) {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `{"content":[{"type":"text","text":`)
	json_write_string(&b, text)
	strings.write_string(&b, `}],"isError":`)
	strings.write_string(&b, is_error ? "true" : "false")
	strings.write_string(&b, "}")
	mcp_write_result(out, id, strings.to_string(b))
}

/*
Add one message to the reply.

The transport puts one message on one line, so a raw newline inside
a message would split it in two. JSON never needs a raw newline: a
newline inside a string arrives as an escape, and a newline between
tokens carries no meaning. So this procedure drops them and ends the
line itself. Every message leaves through here, which keeps the rule
in one place.
*/
mcp_write_line :: proc(out: ^strings.Builder, text: string) {
	strings.builder_grow(out, strings.builder_len(out^) + len(text) + 1)

	for i in 0 ..< len(text) {
		if text[i] == '\n' do continue
		strings.write_byte(out, text[i])
	}
	strings.write_byte(out, '\n')
}

// ------------------------------------------------------------
// Tests (run with: odin test src  from repo root)
// ------------------------------------------------------------

@(test)
test_json_string_escapes :: proc(t: ^testing.T) {
	b := strings.builder_make(context.temp_allocator)
	json_write_string(&b, "a\"b\\c\nd\te")
	testing.expect_value(t, strings.to_string(b), `"a\"b\\c\nd\te"`)
}

@(test)
test_json_string_escapes_control_bytes :: proc(t: ^testing.T) {
	b := strings.builder_make(context.temp_allocator)
	json_write_string(&b, "x\x01y")
	testing.expect_value(t, strings.to_string(b), `"x\u0001y"`)
}

@(test)
test_map_glyphs_survive_the_escape :: proc(t: ^testing.T) {
	// Steam uses a quote as its glyph. The escape must keep the map
	// readable inside a JSON string.
	b := strings.builder_make(context.temp_allocator)
	json_write_string(&b, `~~"~~`)
	testing.expect_value(t, strings.to_string(b), `"~~\"~~"`)
}

@(test)
test_id_round_trip :: proc(t: ^testing.T) {
	number := strings.builder_make(context.temp_allocator)
	json_write_id(&number, json.Integer(42))
	testing.expect_value(t, strings.to_string(number), "42")

	text := strings.builder_make(context.temp_allocator)
	json_write_id(&text, json.String("call-1"))
	testing.expect_value(t, strings.to_string(text), `"call-1"`)

	missing := strings.builder_make(context.temp_allocator)
	json_write_id(&missing, nil)
	testing.expect_value(t, strings.to_string(missing), "null")
}

@(test)
test_field_readers_use_the_fallback :: proc(t: ^testing.T) {
	value, err := json.parse_string(`{"a":7,"b":"text","c":2.5}`, .JSON, true, context.temp_allocator)
	testing.expect(t, err == .None)
	object, ok := value.(json.Object)
	testing.expect(t, ok)

	testing.expect_value(t, json_int_field(object, "a", -1), 7)
	testing.expect_value(t, json_int_field(object, "c", -1), 2)
	testing.expect_value(t, json_int_field(object, "missing", -1), -1)
	testing.expect_value(t, json_string_field(object, "b", ""), "text")
	testing.expect_value(t, json_string_field(object, "a", "fallback"), "fallback")
	testing.expect(t, json_has_field(object, "a"))
	testing.expect(t, !json_has_field(object, "missing"))
}

@(test)
test_initialize_answers_with_the_asked_version :: proc(t: ^testing.T) {
	value, _ := json.parse_string(`{"params":{"protocolVersion":"2024-11-05"}}`, .JSON, true, context.temp_allocator)
	request, _ := value.(json.Object)
	result := mcp_initialize_result(request)
	testing.expect(t, strings.contains(result, `"protocolVersion":"2024-11-05"`), "a known version must come back")

	unknown, _ := json.parse_string(`{"params":{"protocolVersion":"1999-01-01"}}`, .JSON, true, context.temp_allocator)
	unknown_request, _ := unknown.(json.Object)
	fallback := mcp_initialize_result(unknown_request)
	testing.expect(t, strings.contains(fallback, `"protocolVersion":"` + MCP_PROTOCOL + `"`), "an unknown version must fall back")
}
