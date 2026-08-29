package game

import "core:encoding/json"
import "core:strings"
import testing "check"
import rl "vendor:raylib"

MCP_SERVER_NAME    :: "the-game"
MCP_SERVER_VERSION :: "0.1.0"
MCP_PROTOCOL       :: "2025-06-18"

MCP_INSTRUCTIONS :: `You author and run a Noita-like world. There are three parts.

THE BIOME MAP says which biome owns which region. One map pixel is one square
region of the world. Read it with biome_map_view, paint it with
biome_map_paint, write it with biome_map_save. A save is blocked while the
painted map falls into more than one connected piece, because a world the
player cannot walk across is a mistake.

TILE SETS say what a region is made of. A biome with "generator = wang" owns a
set of 512x512 authored tiles, and the world lays them out on a lattice. Each
tile carries a color on each of its four sides, and the world only puts two
tiles side by side when they agree about the side they share, so the pattern
runs on with no seam in it. Open a set with tile_open, pick a tile of it with
tile_select, read it with tile_view, paint it with tile_paint, write the whole
set with tile_save. The cells within 4 of a side belong to the edge color
rather than to the tile, so a stroke there lands in every tile that carries
that color. Painting changes every region of that biome at once.

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

// The protocol owns stdout, and the graphics library writes its trace
// there. So the server shuts that log whatever rung of the debug
// ladder the run is on: one trace line would be a broken frame to the
// client. Everything the server itself says goes to stderr, on a rung.
// See src/noise.odin.
mcp_silence_graphics_log :: proc() {
	rl.SetTraceLogLevel(.NONE)
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

mcp_write_tool_text :: proc(out: ^strings.Builder, id: json.Value, text: string, is_error := false) {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `{"content":[{"type":"text","text":`)
	json_write_string(&b, text)
	strings.write_string(&b, `}],"isError":`)
	strings.write_string(&b, is_error ? "true" : "false")
	strings.write_string(&b, "}")
	mcp_write_result(out, id, strings.to_string(b))
}

mcp_write_line :: proc(out: ^strings.Builder, text: string) {
	strings.builder_grow(out, strings.builder_len(out^) + len(text) + 1)

	for i in 0 ..< len(text) {
		if text[i] == '\n' do continue
		strings.write_byte(out, text[i])
	}
	strings.write_byte(out, '\n')
}

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
