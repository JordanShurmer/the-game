#!/usr/bin/env sh
# Install what the web build needs, on top of tools/install-toolchain.sh:
# emscripten, which links WebAssembly into a page, and a raylib built
# for that page.
#
#   sudo tools/install-web-toolchain.sh    # takes about five minutes
#   make web
#
# Two things are installed, and the second is why this script exists at
# all.
#
# **emscripten.** It is the linker for the web the way clang is the
# linker for the desktop. Odin compiles the game to a WebAssembly object
# and emscripten makes a page of it.
#
# **A raylib for WebGL 2.** Odin vendors a raylib for the web already,
# and the game cannot use it: it is built for WebGL 1, which takes GLSL
# ES 100 and rejects both GLSL ES 300 and every array constructor the
# material prelude is written with. Holding two dialects of every
# material shader is a worse price than building the library once, so
# the library is built once, from the raylib the bindings are cut
# against, with GRAPHICS_API_OPENGL_ES3.
#
# See docs/web.md, "The shaders".
set -eu

# The raylib the Odin bindings are cut against. `vendor/raylib/raylib.odin`
# names it: VERSION_MAJOR, VERSION_MINOR, VERSION_PATCH.
RAYLIB_VERSION="${RAYLIB_VERSION:-6.0}"

# Where the unpacked tree goes. Under `sudo` the environment's HOME is
# root's, and /root is closed to everybody else: a compiler unpacked
# there answers "Permission denied" to the very user who asked for it,
# which is what a CI runner and a shared machine both see. So the home
# that counts is the one of whoever called sudo.
if [ -n "${SUDO_USER:-}" ] && [ -z "${WORK:-}" ]; then
	WORK=$(eval echo "~$SUDO_USER")
fi
WORK="${WORK:-$HOME}"
EMSDK="${EMSDK:-$WORK/emsdk}"
RAYLIB_SRC="${RAYLIB_SRC:-$WORK/raylib-$RAYLIB_VERSION}"
RAYLIB_WEB="${RAYLIB_WEB:-/usr/local/lib/raylib-web}"

say() { printf '\n== %s\n' "$1"; }

say "packages"
apt-get update -qq
apt-get install -y --no-install-recommends git make python3 xz-utils ca-certificates

say "emscripten"
if [ ! -d "$EMSDK" ]; then
	git clone --depth 1 https://github.com/emscripten-core/emsdk.git "$EMSDK"
fi
"$EMSDK/emsdk" install latest
"$EMSDK/emsdk" activate latest

# emsdk_env.sh is not a POSIX shell script, and this one is: the tools
# are taken by their path instead, which is what the Makefile does too.
PATH="$EMSDK/upstream/emscripten:$PATH"
export PATH
emcc --version | sed -n 1p

say "raylib $RAYLIB_VERSION for WebGL 2"
if [ ! -d "$RAYLIB_SRC" ]; then
	git clone --depth 1 --branch "$RAYLIB_VERSION" \
		https://github.com/raysan5/raylib.git "$RAYLIB_SRC"
fi
make -C "$RAYLIB_SRC/src" PLATFORM=PLATFORM_WEB GRAPHICS=GRAPHICS_API_OPENGL_ES3 -j"$(nproc)"

# An ar archive, not a stub: the same check the desktop toolchain makes.
head -c 8 "$RAYLIB_SRC/src/libraylib.web.a" | grep -q '^!<arch>' || {
	echo "$RAYLIB_SRC/src/libraylib.web.a is not a library" >&2
	exit 1
}

say "install"
mkdir -p "$RAYLIB_WEB"
cp "$RAYLIB_SRC/src/libraylib.web.a" "$RAYLIB_WEB/libraylib.web.a"
ls -l "$RAYLIB_WEB/libraylib.web.a"

printf '\nBuild the page from the repository root: make web\n'
