#+build !freestanding
package check

// The test package, on a machine that can run tests.
//
// `core:testing` reaches `core:os`, and `core:os` does not build for
// WebAssembly at all. The tests live beside the code they cover, in the
// same files, so a build of the game for the browser is a build of the
// tests as well: one import of `core:testing` anywhere in the package
// and the whole build stops.
//
// So the package imports this instead. Here it is `core:testing`, name
// for name -- `odin test src` runs what it always ran, and `^check.T`
// is `^testing.T` and not a copy of it. In the browser it is
// `check_web.odin`, which is the same four names doing nothing.
//
// See docs/web.md, "What the web cannot have".

import "core:testing"

T :: testing.T

expect       :: testing.expect
expectf      :: testing.expectf
expect_value :: testing.expect_value
