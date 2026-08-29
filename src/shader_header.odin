package game

// The first lines of every shader the game loads, and the only part of
// one that is not the same on a desktop and in a browser.
//
// Desktop OpenGL takes GLSL 330. WebGL 2 takes GLSL ES 300. For
// everything the game writes -- `in`, `out`, `texture`, an array
// constructor, a loop over a count it is handed -- the two are the same
// language, so no shader file names a version and the loader puts the
// header on. A material is still one file that works on both.
//
// ES leaves a fragment shader with no precision of its own, so the
// browser's header names one. `highp` is what the shape and the light
// need: the g-buffer is read at a texel, and a `mediump` float loses
// the cell before the picture does.
//
// See docs/web.md, "The shaders".

when ODIN_ARCH == .wasm32 || ODIN_ARCH == .wasm64p32 {
	SHADER_HEADER :: "#version 300 es\nprecision highp float;\nprecision highp int;\n"
} else {
	SHADER_HEADER :: "#version 330\n"
}
