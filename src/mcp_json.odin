package game

import "core:encoding/json"
import "core:fmt"
import "core:strings"

json_object_field :: proc(object: json.Object, key: string) -> (json.Object, bool) {
	value, found := object[key]
	if !found do return {}, false
	inner, ok := value.(json.Object)
	return inner, ok
}

json_int_field :: proc(object: json.Object, key: string, fallback: i64) -> i64 {
	value, found := object[key]
	if !found do return fallback
	#partial switch item in value {
	case json.Integer:
		return item
	case json.Float:
		return i64(item)
	}
	return fallback
}

json_number_field :: proc(object: json.Object, key: string, fallback: f64) -> f64 {
	value, found := object[key]
	if !found do return fallback
	#partial switch item in value {
	case json.Float:
		return item
	case json.Integer:
		return f64(item)
	}
	return fallback
}

json_string_field :: proc(object: json.Object, key: string, fallback: string) -> string {
	value, found := object[key]
	if !found do return fallback
	text, ok := value.(json.String)
	return ok ? string(text) : fallback
}

json_has_field :: proc(object: json.Object, key: string) -> bool {
	_, found := object[key]
	return found
}

json_bool_field :: proc(object: json.Object, key: string, fallback: bool) -> bool {
	value, found := object[key]
	if !found do return fallback
	b, ok := value.(json.Boolean)
	return ok ? bool(b) : fallback
}

json_rows_field :: proc(object: json.Object, key: string, allocator := context.temp_allocator) -> (rows: []string, found: bool) {
	value, has := object[key]
	if !has do return nil, false

	array, is_array := value.(json.Array)
	if !is_array do return nil, false

	out := make([dynamic]string, allocator)
	for item in array {
		text, is_text := item.(json.String)
		if !is_text do return nil, false
		append(&out, string(text))
	}
	return out[:], true
}

json_write_string :: proc(b: ^strings.Builder, text: string) {
	strings.write_byte(b, '"')
	for i in 0 ..< len(text) {
		c := text[i]
		switch c {
		case '"':
			strings.write_string(b, "\\\"")
		case '\\':
			strings.write_string(b, "\\\\")
		case '\n':
			strings.write_string(b, "\\n")
		case '\r':
			strings.write_string(b, "\\r")
		case '\t':
			strings.write_string(b, "\\t")
		case:
			if c < 0x20 {
				fmt.sbprintf(b, "\\u%04x", u32(c))
			} else {
				strings.write_byte(b, c)
			}
		}
	}
	strings.write_byte(b, '"')
}

json_write_id :: proc(b: ^strings.Builder, id: json.Value) {
	#partial switch item in id {
	case json.Integer:
		fmt.sbprintf(b, "%d", item)
	case json.Float:
		fmt.sbprintf(b, "%d", i64(item))
	case json.String:
		json_write_string(b, string(item))
	case:
		strings.write_string(b, "null")
	}
}
