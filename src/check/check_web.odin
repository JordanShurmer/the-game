#+build freestanding
package check

// The test package, in the browser, where no test is ever run.
//
// The tests are compiled all the same, because they sit in the files
// the game is made of. These four names are what they call. They hold
// the shape of `core:testing` and none of its behaviour, so a test body
// still has to say something true about types, which is most of what a
// test says.
//
// See check_desktop.odin, and docs/web.md.

T :: struct {}

expect :: proc(t: ^T, condition: bool, message := "", loc := #caller_location) -> bool {
	return condition
}

expectf :: proc(t: ^T, condition: bool, format: string, args: ..any, loc := #caller_location) -> bool {
	return condition
}

expect_value :: proc(t: ^T, value, expected: $V, loc := #caller_location) -> bool {
	return value == expected
}
