#!/usr/bin/env sh
# Install the toolchain the game needs: the Odin compiler and the raylib
# library its vendor bindings link against.
#
#   sudo tools/install-toolchain.sh        # takes about half a minute
#
# The game needs no toolchain of its own. This script exists because a
# fresh container has none.
#
# Odin publishes a release archive that holds the compiler, the core
# libraries, and the vendored binaries. The compiler in it is static,
# so it needs no LLVM on the machine, and the raylib archive in it is
# the real library. Nothing is built here, and nothing is cloned.
#
# Do not clone the Odin repository for this. The vendored binaries live
# in Git LFS, so a clone gives a pointer file where the library should
# be, and the link then fails with missing symbols. The release archive
# has no such problem.
#
# Set ODIN_RELEASE to install another release. It must be a tag of the
# Odin repository that carries release archives.
set -eu

ODIN_RELEASE="${ODIN_RELEASE:-dev-2026-08}"
PREFIX="${PREFIX:-/usr/local/bin}"
WORK="${WORK:-$HOME}"

# RAYLIB_DIR is where the bindings look for the library on this arch.
case "$(uname -m)" in
	x86_64)          ARCH=amd64; RAYLIB_DIR=linux ;;
	aarch64 | arm64) ARCH=arm64; RAYLIB_DIR=linux-arm64 ;;
	*) echo "no Odin release for $(uname -m)" >&2; exit 1 ;;
esac

say() { printf '\n== %s\n' "$1"; }

say "packages"
apt-get update -qq
# clang is the linker Odin calls. libx11-dev is what the static raylib
# links against; raylib loads OpenGL at run time, so no GL package is
# needed to build. make is for the Makefile targets.
apt-get install -y --no-install-recommends \
	clang make curl ca-certificates libx11-dev

say "odin $ODIN_RELEASE ($ARCH)"
DEST="$WORK/odin-$ODIN_RELEASE-$ARCH"
if [ ! -x "$DEST/odin" ]; then
	# Unpack beside the target and move it, so an interrupted download
	# does not leave a half tree that the next run takes for a whole one.
	rm -rf "$DEST.part"
	mkdir -p "$DEST.part"
	curl -fL --retry 3 -o "$DEST.part/odin.tar.gz" \
		"https://github.com/odin-lang/Odin/releases/download/$ODIN_RELEASE/odin-linux-$ARCH-$ODIN_RELEASE.tar.gz"
	tar xzf "$DEST.part/odin.tar.gz" -C "$DEST.part" --strip-components=1
	rm -f "$DEST.part/odin.tar.gz"
	mv "$DEST.part" "$DEST"
fi

# A Git LFS pointer is a small text file. The library is an ar archive.
# This catches an archive that was published or unpacked wrong, which
# would otherwise show up much later as missing symbols at link time.
RAYLIB="$DEST/vendor/raylib/$RAYLIB_DIR/libraylib.a"
head -c 8 "$RAYLIB" | grep -q '^!<arch>' || {
	echo "$RAYLIB is not a library" >&2
	exit 1
}

say "install"
ln -sf "$DEST/odin" "$PREFIX/odin"
odin version

printf '\nRun the tests from the repository root: odin test src\n'
