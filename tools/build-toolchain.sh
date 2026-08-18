#!/usr/bin/env sh
# Build the toolchain the game needs: the Odin compiler and the raylib
# library its vendor bindings link against.
#
#   sudo tools/build-toolchain.sh          # takes about five minutes
#
# The game needs no toolchain of its own. This script exists because a
# fresh container has none, and because the raylib part is not obvious:
# the Odin repository keeps its vendored binaries in Git LFS, and a
# clone that cannot reach LFS gets a pointer file instead of a library.
# Building raylib from source gives the same archive, byte for byte.
#
# Set ODIN_RELEASE to build another release. It must be a tag of the
# Odin repository, and RAYLIB_TAG must be the raylib version that
# release binds to (see vendor/raylib/raylib.odin, VERSION).
set -eu

ODIN_RELEASE="${ODIN_RELEASE:-dev-2026-08}"
RAYLIB_TAG="${RAYLIB_TAG:-6.0}"
PREFIX="${PREFIX:-/usr/local/bin}"
WORK="${WORK:-$HOME}"

say() { printf '\n== %s\n' "$1"; }

say "packages"
apt-get update -qq
# llvm-18-dev holds the headers and libraries the compiler links to;
# the X development packages are what raylib builds its window on.
apt-get install -y --no-install-recommends \
	llvm-18-dev clang git make \
	libx11-dev libxrandr-dev libxinerama-dev libxcursor-dev libxi-dev libgl1-mesa-dev

say "odin $ODIN_RELEASE"
if [ ! -d "$WORK/odin" ]; then
	git clone --depth 1 --branch "$ODIN_RELEASE" https://github.com/odin-lang/Odin "$WORK/odin"
fi
cd "$WORK/odin"
./build_odin.sh release

say "raylib $RAYLIB_TAG"
if [ ! -d "$WORK/raylib" ]; then
	git clone --depth 1 --branch "$RAYLIB_TAG" https://github.com/raysan5/raylib "$WORK/raylib"
fi
cd "$WORK/raylib/src"
make PLATFORM=PLATFORM_DESKTOP_GLFW RAYLIB_LIBTYPE=STATIC RAYLIB_BUILD_MODE=RELEASE

# The bindings link this path. The file the Odin repository ships here
# is a Git LFS pointer until it is fetched, so overwrite it.
cp libraylib.a "$WORK/odin/vendor/raylib/linux/libraylib.a"

say "install"
ln -sf "$WORK/odin/odin" "$PREFIX/odin"
odin version

printf '\nRun the tests from the repository root: odin test src\n'
