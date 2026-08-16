package game

import "core:fmt"
import "core:strconv"
import "core:strings"

/*
Shared config tokenizer for materials.txt, biomes.txt, and tileset sidecars.

A parse failure or unknown name is an error. Silent defaults are not allowed.
*/

Config_Error :: struct {
	file: string,
	line: int,
	text: string,
	msg:  string,
}

Config_KV :: struct {
	key:   string,
	value: string,
	line:  int,
}

Config_Section :: struct {
	name: string,
	line: int,
	kvs:  []Config_KV,
}

// Parse 0x-prefixed or bare hex into u32.
// parse_u64_of_base does not strip a 0x prefix, so we do it here.
parse_hex_u32 :: proc(s: string) -> (v: u32, ok: bool) {
	s := strings.trim_space(s)
	if len(s) >= 2 && s[0] == '0' && (s[1] == 'x' || s[1] == 'X') {
		s = s[2:]
	}
	if len(s) == 0 {
		return 0, false
	}
	n, vok := strconv.parse_u64_of_base(s, 16)
	if !vok {
		return 0, false
	}
	return u32(n), true
}

strip_inline_comment :: proc(s: string) -> string {
	if idx := strings.index_byte(s, '#'); idx >= 0 {
		return strings.trim_space(s[:idx])
	}
	return strings.trim_space(s)
}

// Tokenize a whole file into sections.
// Section names and key/value strings are views into `text`.
// The returned slices are allocated; free with free_config_sections.
tokenize_config :: proc(
	text: string,
	file: string,
	allocator := context.allocator,
) -> (sections: []Config_Section, err: Config_Error, ok: bool) {
	secs := make([dynamic]Config_Section, allocator)

	current_kvs := make([dynamic]Config_KV, allocator)
	current_name: string
	current_line: int
	has_section := false
	line_no := 0

	text := text
	for line in strings.split_lines_iterator(&text) {
		line_no += 1
		trimmed := strings.trim_space(line)
		if len(trimmed) == 0 || trimmed[0] == '#' {
			continue
		}

		// Strip trailing comment before testing for a section header so
		// "[Coalmine]  # note" is still a section.
		body := strip_inline_comment(trimmed)
		if len(body) == 0 {
			continue
		}

		if body[0] == '[' {
			if body[len(body)-1] != ']' {
				err = Config_Error{file, line_no, body, "section header must end with ]"}
				free_config_sections(secs[:], allocator)
				delete(current_kvs)
				return {}, err, false
			}
			if has_section {
				append(&secs, Config_Section{
					name = current_name,
					line = current_line,
					kvs  = current_kvs[:],
				})
				current_kvs = make([dynamic]Config_KV, allocator)
			}
			current_name = body[1:len(body)-1]
			current_line = line_no
			has_section = true
			continue
		}

		if !has_section {
			err = Config_Error{file, line_no, body, "key outside any section"}
			free_config_sections(secs[:], allocator)
			delete(current_kvs)
			return {}, err, false
		}

		eq := strings.index_byte(body, '=')
		if eq < 0 {
			err = Config_Error{file, line_no, body, "expected key = value"}
			free_config_sections(secs[:], allocator)
			delete(current_kvs)
			return {}, err, false
		}
		key := strings.trim_space(body[:eq])
		value := strings.trim_space(body[eq+1:])
		if len(key) == 0 {
			err = Config_Error{file, line_no, body, "empty key"}
			free_config_sections(secs[:], allocator)
			delete(current_kvs)
			return {}, err, false
		}
		append(&current_kvs, Config_KV{key = key, value = value, line = line_no})
	}

	if has_section {
		append(&secs, Config_Section{
			name = current_name,
			line = current_line,
			kvs  = current_kvs[:],
		})
	} else {
		delete(current_kvs)
	}

	return secs[:], {}, true
}

free_config_sections :: proc(sections: []Config_Section, allocator := context.allocator) {
	for s in sections {
		delete(s.kvs, allocator)
	}
	delete(sections, allocator)
}

format_config_error :: proc(err: Config_Error, allocator := context.allocator) -> string {
	return fmt.tprintf("%s:%d: %s (%q)", err.file, err.line, err.msg, err.text)
}
