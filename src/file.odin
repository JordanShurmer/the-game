package game

// One way to reach a file.
//
// The game reads every file it ships through raylib, and not through
// `core:os`. The reason is the browser: `core:os` does not build for
// WebAssembly at all, and raylib's own reader builds everywhere. In the
// browser the data files sit inside the page, laid out by emscripten
// under the same names, so `data/materials.txt` is one path on every
// target and no loader knows which target it is on.
//
// See docs/web.md, "What the web cannot have".

import "core:c"
import "core:strings"
import rl "vendor:raylib"

@(private = "file")
c_path :: proc(path: string) -> cstring {
	return strings.clone_to_cstring(path, context.temp_allocator)
}

// The whole file, in the caller's allocator. raylib reads it into its
// own memory, so the bytes are copied out and given back at once: a
// caller that has to `delete` half its data and `rl.UnloadFileData` the
// other half is a caller that will free the wrong one.
file_read :: proc(path: string, allocator := context.allocator) -> (data: []byte, ok: bool) {
	size: c.int
	raw := rl.LoadFileData(c_path(path), &size)
	if raw == nil do return nil, false
	defer rl.UnloadFileData(raw)

	if size <= 0 do return nil, true

	out := make([]byte, int(size), allocator)
	copy(out, raw[:size])
	return out, true
}

file_exists :: proc(path: string) -> bool {
	return bool(rl.FileExists(c_path(path)))
}

file_write :: proc(path: string, data: []byte) -> bool {
	return bool(rl.SaveFileData(c_path(path), raw_data(data), c.int(len(data))))
}

// Only a test writes a file it then has to take away. raylib has no
// call for it, so this is the one place the game names a C library
// procedure. `core:c/libc` brings the whole header and does not build
// for WebAssembly; one line of it does.
@(default_calling_convention = "c")
foreign _ {
	remove :: proc(path: cstring) -> c.int ---
}

file_remove :: proc(path: string) {
	remove(c_path(path))
}

// The reel writes its frames into a directory it is given, which may
// not be there yet.
file_make_directory :: proc(path: string) -> bool {
	return rl.MakeDirectory(c_path(path)) == 0
}

// Every file in a directory with the named extension, sorted the way
// raylib returns them. The names come back in the caller's allocator.
file_list :: proc(dir, ext: string, allocator := context.allocator) -> []string {
	found := rl.LoadDirectoryFilesEx(c_path(dir), c_path(ext), false)
	defer rl.UnloadDirectoryFiles(found)

	out := make([]string, int(found.count), allocator)
	for i in 0 ..< int(found.count) {
		out[i] = strings.clone(string(found.paths[i]), allocator)
	}
	return out
}
