#+build !amd64
package game

// The wide weight pass stands down. Its templates are amd64, so every
// other machine — an arm64 desktop, and the WebAssembly the browser
// runs — loads weights one cell at a time. `sandbox_load_weights` asks
// `table.wide_ok` first, and these three answers leave it false and the
// span untouched. See docs/web.md.

sandbox_wide_cpu :: proc "contextless" () -> bool {
	return false
}

// The span the wide pass would take, which is none of it.
sandbox_wide_start :: #force_inline proc "contextless" (from, last: i32) -> i32 {
	return from
}

sandbox_weights_span :: proc(
	sb: ^Sandbox, table: Material_Table, out: []u16, base: int, from, last: i32,
) -> i32 {
	return from
}
