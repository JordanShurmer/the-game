package game

import "core:encoding/json"
import "core:strings"
import "core:testing"

/*
End to end tests for the MCP server.

These tests drive `mcp_handle`, which is the same entry point that
the transport uses. They check the messages that a client would
receive, not the pieces behind them.
*/

@(private = "file")
Session :: struct {
	sim: Sim,
}

@(private = "file")
session_start :: proc(t: ^testing.T) -> Session {
	session: Session
	err := sim_load(&session.sim)
	testing.expect(t, err == .None, "the session must start")
	sim_open_sandbox(&session.sim, 32, 20, 0, 0, 3, 2)
	return session
}

@(private = "file")
session_stop :: proc(session: ^Session) {
	sim_unload(&session.sim)
}

// Send one message and return the raw reply, which may be empty.
@(private = "file")
send :: proc(session: ^Session, message: string) -> string {
	out := strings.builder_make(context.temp_allocator)
	mcp_handle(&session.sim, message, &out)
	return strings.to_string(out)
}

// Send one message and read the reply as JSON.
@(private = "file")
send_json :: proc(t: ^testing.T, session: ^Session, message: string) -> json.Object {
	reply := send(session, message)
	testing.expect(t, len(reply) > 0, "the message must produce a reply")

	value, err := json.parse_string(strings.trim_space(reply), .JSON, true, context.temp_allocator)
	testing.expect(t, err == .None, "the reply must be valid JSON")

	object, ok := value.(json.Object)
	testing.expect(t, ok, "the reply must be an object")
	return object
}

// Read the text that a tool call produced.
@(private = "file")
tool_text :: proc(t: ^testing.T, reply: json.Object) -> (text: string, is_error: bool) {
	result, has_result := json_object_field(reply, "result")
	testing.expect(t, has_result, "a tool call must answer with a result")

	content, has_content := result["content"]
	testing.expect(t, has_content, "a tool result must hold content")

	items, is_array := content.(json.Array)
	testing.expect(t, is_array && len(items) == 1, "one block of content is expected")

	block, is_object := items[0].(json.Object)
	testing.expect(t, is_object)
	testing.expect_value(t, json_string_field(block, "type", ""), "text")

	if flag, has_flag := result["isError"]; has_flag {
		is_error, _ = flag.(json.Boolean)
	}
	return json_string_field(block, "text", ""), is_error
}

@(private = "file")
call :: proc(t: ^testing.T, session: ^Session, id: int, body: string) -> (string, bool) {
	message := strings.concatenate(
		{`{"jsonrpc":"2.0","id":`, fmt_int(id), `,"method":"tools/call","params":`, body, `}`},
		context.temp_allocator,
	)
	return tool_text(t, send_json(t, session, message))
}

@(private = "file")
fmt_int :: proc(value: int) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_int(&b, value)
	return strings.to_string(b)
}

@(test)
test_session_handshake :: proc(t: ^testing.T) {
	session := session_start(t)
	defer session_stop(&session)

	reply := send_json(t, &session,
		`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{}}}`)

	testing.expect_value(t, json_string_field(reply, "jsonrpc", ""), "2.0")
	testing.expect_value(t, json_int_field(reply, "id", -1), 1)

	result, ok := json_object_field(reply, "result")
	testing.expect(t, ok, "initialize must answer with a result")
	testing.expect_value(t, json_string_field(result, "protocolVersion", ""), "2025-06-18")

	server, has_server := json_object_field(result, "serverInfo")
	testing.expect(t, has_server)
	testing.expect_value(t, json_string_field(server, "name", ""), MCP_SERVER_NAME)

	capabilities, has_capabilities := json_object_field(result, "capabilities")
	testing.expect(t, has_capabilities, "the server must state its capabilities")
	_, has_tools := json_object_field(capabilities, "tools")
	testing.expect(t, has_tools, "the server must offer tools")
}

@(test)
test_session_never_answers_a_notification :: proc(t: ^testing.T) {
	session := session_start(t)
	defer session_stop(&session)

	reply := send(&session, `{"jsonrpc":"2.0","method":"notifications/initialized"}`)
	testing.expect_value(t, len(reply), 0)
}

@(test)
test_every_reply_is_one_line :: proc(t: ^testing.T) {
	// The transport reads one message per line, so a reply that holds
	// a newline would break the stream. The map is the real risk: it
	// is full of newlines before the escape runs.
	session := session_start(t)
	defer session_stop(&session)

	messages := []string {
		`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}`,
		`{"jsonrpc":"2.0","id":2,"method":"tools/list"}`,
		`{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"list_materials","arguments":{}}}`,
		`{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"observe","arguments":{}}}`,
		`{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"world_status","arguments":{}}}`,
	}

	for message in messages {
		reply := send(&session, message)
		testing.expect(t, len(reply) > 0, "each message must produce a reply")
		testing.expect_value(t, strings.count(reply, "\n"), 1)
		testing.expect(t, strings.has_suffix(reply, "\n"), "the newline must end the line")

		_, err := json.parse_string(strings.trim_space(reply), .JSON, true, context.temp_allocator)
		testing.expect(t, err == .None, "each reply must be valid JSON")
	}
}

@(test)
test_session_reports_bad_json :: proc(t: ^testing.T) {
	session := session_start(t)
	defer session_stop(&session)

	reply := send_json(t, &session, `{"jsonrpc":"2.0","id":1,`)
	error, ok := json_object_field(reply, "error")
	testing.expect(t, ok, "broken JSON must answer with an error")
	testing.expect_value(t, json_int_field(error, "code", 0), -32700)
}

@(test)
test_session_reports_an_unknown_method :: proc(t: ^testing.T) {
	session := session_start(t)
	defer session_stop(&session)

	reply := send_json(t, &session, `{"jsonrpc":"2.0","id":9,"method":"resources/list"}`)
	error, ok := json_object_field(reply, "error")
	testing.expect(t, ok, "an unknown method must answer with an error")
	testing.expect_value(t, json_int_field(error, "code", 0), -32601)
	testing.expect_value(t, json_int_field(reply, "id", -1), 9)
}

@(test)
test_session_keeps_a_string_id :: proc(t: ^testing.T) {
	session := session_start(t)
	defer session_stop(&session)

	reply := send_json(t, &session, `{"jsonrpc":"2.0","id":"call-7","method":"ping"}`)
	testing.expect_value(t, json_string_field(reply, "id", ""), "call-7")
}

@(test)
test_session_plays_a_full_turn :: proc(t: ^testing.T) {
	session := session_start(t)
	defer session_stop(&session)

	send(&session, `{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}`)

	// Open on the Sky biome, which fills with Air, so the terrain
	// behind does not hide the sand.
	call(t, &session, 1, `{"name":"sandbox_open","arguments":{"x":0,"y":-4000,"width":32,"height":20}}`)

	// A command waits for its tick.
	queued, queue_failed := call(t, &session, 2,
		`{"name":"enqueue_input","arguments":{"kind":"spawn","x":16,"y":0,"radius":2,"material":"Sand"}}`)
	testing.expect(t, !queue_failed)
	testing.expect(t, strings.contains(queued, "runs on tick 2"))

	// The world must not change before that tick.
	early, _ := call(t, &session, 3, `{"name":"tick","arguments":{"count":1}}`)
	testing.expect(t, strings.contains(early, "applied 0 commands"))
	testing.expect(t, !strings.contains(early, "Sand"), "no sand before the command runs")

	// The tick arrives and the command runs.
	late, _ := call(t, &session, 4, `{"name":"tick","arguments":{"count":10}}`)
	testing.expect(t, strings.contains(late, "applied 1 commands"))
	testing.expect(t, strings.contains(late, "Sand"))

	// The map shows the result.
	map_text, map_failed := call(t, &session, 5, `{"name":"observe","arguments":{}}`)
	testing.expect(t, !map_failed)
	testing.expect(t, strings.contains(map_text, "s=Sand"), "the sand must appear on the map")
}

@(test)
test_session_reports_a_tool_fault_as_a_result :: proc(t: ^testing.T) {
	// A fault inside a tool is not a protocol fault. The client must
	// still get a result, with isError set, so the model can read the
	// reason and correct itself.
	session := session_start(t)
	defer session_stop(&session)

	text, is_error := call(t, &session, 1,
		`{"name":"enqueue_input","arguments":{"kind":"spawn","x":1,"y":1,"material":"Cheese"}}`)
	testing.expect(t, is_error, "the tool must report the fault")
	testing.expect(t, strings.contains(text, "Cheese"), "the reason must name the fault")

	unknown, unknown_error := call(t, &session, 2, `{"name":"fly","arguments":{}}`)
	testing.expect(t, unknown_error)
	testing.expect(t, strings.contains(unknown, "unknown tool"))
}

@(test)
test_session_repeats_a_run_from_a_seed :: proc(t: ^testing.T) {
	// The promise of the queue: the same seed and the same commands
	// give the same world. A client can check the checksum to be sure
	// that a replay matched.
	play :: proc(t: ^testing.T) -> string {
		session := session_start(t)
		defer session_stop(&session)

		call(t, &session, 1, `{"name":"sandbox_open","arguments":{"x":0,"y":-4000,"width":40,"height":24,"seed":2024,"input_delay":1}}`)
		call(t, &session, 2, `{"name":"enqueue_input","arguments":{"kind":"spawn","x":20,"y":2,"radius":4,"material":"Oil"}}`)
		call(t, &session, 3, `{"name":"tick","arguments":{"count":20}}`)
		call(t, &session, 4, `{"name":"enqueue_input","arguments":{"kind":"ignite","x":20,"y":20,"radius":6}}`)
		call(t, &session, 5, `{"name":"tick","arguments":{"count":60}}`)

		status, _ := call(t, &session, 6, `{"name":"world_status","arguments":{}}`)
		return strings.clone(status, context.temp_allocator)
	}

	first  := play(t)
	second := play(t)
	testing.expect_value(t, first, second)
	testing.expect(t, strings.contains(first, "checksum 0x"), "the status must carry a checksum")
}

@(test)
test_session_fire_burns_the_oil_away :: proc(t: ^testing.T) {
	// A whole chain of rules, driven only through the protocol:
	// oil falls, an ignite command sets it alight, the fire runs
	// through the pool, and smoke rises from what is left.
	session := session_start(t)
	defer session_stop(&session)

	call(t, &session, 1, `{"name":"sandbox_open","arguments":{"x":0,"y":-4000,"width":40,"height":16,"seed":11,"input_delay":0}}`)
	call(t, &session, 2, `{"name":"enqueue_input","arguments":{"kind":"spawn","x":20,"y":14,"radius":5,"material":"Oil"}}`)
	call(t, &session, 3, `{"name":"tick","arguments":{"count":20}}`)

	before, _ := call(t, &session, 4, `{"name":"world_status","arguments":{}}`)
	testing.expect(t, strings.contains(before, "Oil"), "the oil must be in the world")

	// The ignite covers the whole pool, and the ground the collapse
	// threw a grain of oil across as well. A liquid packs into one
	// body now instead of holding the holes it fell with, so a grain
	// left clear of that body stays clear, and fire cannot cross the
	// gap to it.
	call(t, &session, 5, `{"name":"enqueue_input","arguments":{"kind":"ignite","x":20,"y":15,"radius":12}}`)
	call(t, &session, 6, `{"name":"tick","arguments":{"count":400}}`)

	after, _ := call(t, &session, 7, `{"name":"world_status","arguments":{}}`)
	testing.expect(t, !strings.contains(after, "Oil"), "the fire must burn the oil away")
}
