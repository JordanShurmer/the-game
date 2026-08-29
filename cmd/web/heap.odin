package main

// The heap, in a page.
//
// A freestanding WebAssembly target has no allocator at all: Odin's
// default one answers Out_Of_Memory to the first byte asked of it, and
// the default temporary allocator is a nil allocator. Both have to come
// from the page, and emscripten's own malloc is what the page has.
//
// It is also what raylib allocates through, so the game and the library
// it draws with share one heap, and the memory the page grows is the
// memory both of them use.

import "base:runtime"
import "core:c"

@(default_calling_convention = "c")
foreign _ {
	malloc        :: proc(size: c.size_t) -> rawptr ---
	free          :: proc(ptr: rawptr) ---
	aligned_alloc :: proc(alignment: c.size_t, size: c.size_t) -> rawptr ---
	memset        :: proc(ptr: rawptr, value: c.int, size: c.size_t) -> rawptr ---
	memcpy        :: proc(dst: rawptr, src: rawptr, size: c.size_t) -> rawptr ---
}

heap_allocator :: proc() -> runtime.Allocator {
	return {procedure = heap_allocator_proc, data = nil}
}

heap_allocator_proc :: proc(
	data: rawptr,
	mode: runtime.Allocator_Mode,
	size, alignment: int,
	old_memory: rawptr,
	old_size: int,
	loc := #caller_location,
) -> (
	[]byte,
	runtime.Allocator_Error,
) {
	// aligned_alloc wants a size that is a whole number of alignments,
	// and every allocation here asks for one alignment or another.
	take :: proc(size, alignment: int) -> rawptr {
		if size <= 0 do return nil
		if alignment <= size_of(rawptr) do return malloc(c.size_t(size))
		rounded := (size + alignment - 1) & ~(alignment - 1)
		return aligned_alloc(c.size_t(alignment), c.size_t(rounded))
	}

	switch mode {
	case .Alloc, .Alloc_Non_Zeroed:
		ptr := take(size, alignment)
		if ptr == nil do return nil, .Out_Of_Memory
		if mode == .Alloc do memset(ptr, 0, c.size_t(size))
		return ([^]byte)(ptr)[:size], nil

	case .Free:
		free(old_memory)
		return nil, nil

	case .Resize, .Resize_Non_Zeroed:
		// Grown by hand rather than with realloc, because realloc keeps
		// no alignment, and an aligned block moved to an unaligned one
		// is a fault a long way from here.
		ptr := take(size, alignment)
		if ptr == nil && size > 0 do return nil, .Out_Of_Memory
		if old_memory != nil {
			kept := min(old_size, size)
			if kept > 0 do memcpy(ptr, old_memory, c.size_t(kept))
			free(old_memory)
		}
		if mode == .Resize && size > old_size {
			memset(rawptr(uintptr(ptr) + uintptr(old_size)), 0, c.size_t(size - old_size))
		}
		return ([^]byte)(ptr)[:size], nil

	case .Free_All:
		return nil, .Mode_Not_Implemented

	case .Query_Features:
		set := (^runtime.Allocator_Mode_Set)(old_memory)
		if set != nil {
			set^ = {.Alloc, .Alloc_Non_Zeroed, .Free, .Resize, .Resize_Non_Zeroed, .Query_Features}
		}
		return nil, nil

	case .Query_Info:
		return nil, .Mode_Not_Implemented
	}

	return nil, nil
}
