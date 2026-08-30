#!/usr/bin/env sh
# Install the toolchain the game needs: the Odin compiler and the raylib
# library its vendor bindings link against.
#
#   sudo tools/install-toolchain.sh        # takes about half a minute
#
# It says one line when it is done: the compiler it installed. The
# debug ladder is the same one the rest of the toolset reads, and it
# is set here with -v:
#
#   sudo tools/install-toolchain.sh -v     # a line for each step
#   sudo tools/install-toolchain.sh -vv    # apt and curl speak too
#   sudo tools/install-toolchain.sh -vvv   # every command, traced
#
# The game needs no toolchain of its own. This script exists because a
# fresh container has none.
#
# Odin publishes two kinds of archive, and both hold the compiler, the
# core libraries, and the vendored binaries. A RELEASE archive is cut
# once a month and is kept for ever. A NIGHTLY archive is cut from the
# tip of master every day, and only the last eight days are kept.
#
# The game takes a nightly, because it uses `asm` templates and those
# reached master after the dev-2026-08 release was cut. See
# docs/toolchain.md, "Why a nightly".
#
#   ODIN_NIGHTLY=2026-08-20 sudo tools/install-toolchain.sh   # that day
#   ODIN_NIGHTLY=latest     sudo tools/install-toolchain.sh   # the newest
#   ODIN_RELEASE=dev-2026-09 sudo tools/install-toolchain.sh  # a release
#
# ODIN_NIGHTLY defaults to the day the game was last tested against. A
# nightly is dropped eight days after it is cut, so that day goes away
# on its own. The script then takes the newest nightly there is and
# says so, which keeps a checkout that is a month old installable.
#
# Nothing is built here, and nothing is cloned. Do not clone the Odin
# repository for this: the vendored binaries live in Git LFS, so a
# clone gives a pointer file where the library should be, and the link
# then fails with missing symbols. Both archives hold the real library.
set -eu

USAGE="usage: install-toolchain.sh [-v|-vv|-vvv]

Installs the Odin compiler the game builds with, and the packages it
links against. Needs root, and the network.

  ODIN_NIGHTLY=latest      take the newest nightly
  ODIN_RELEASE=dev-2026-09 take a release archive instead
  PREFIX=/usr/local/bin    where the odin symlink goes"

DEBUG="${GAME_DEBUG:-0}"
for arg in "$@"; do
	case "$arg" in
		-h | --help) echo "$USAGE"; exit 0 ;;
		-v)   DEBUG=1 ;;
		-vv)  DEBUG=2 ;;
		-vvv) DEBUG=3 ;;
		-d[0-3]) DEBUG=${arg#-d} ;;
		*) echo "there is no option $arg" >&2; echo "$USAGE" >&2; exit 1 ;;
	esac
done
export GAME_DEBUG="$DEBUG"

# Under `set -e` a bare test that comes out false would end the run.
if [ "$DEBUG" -ge 3 ]; then
	set -x
fi

# Below the second rung the tools that fetch and unpack keep their
# progress to themselves: a run that goes right has nothing to report
# but the compiler it installed.
if [ "$DEBUG" -ge 2 ]; then
	APT_QUIET=""
	APT_SINK="/dev/stdout"
	CURL_QUIET=""
	TAR_QUIET="-v"
else
	APT_QUIET="-qq"
	APT_SINK="/dev/null"
	CURL_QUIET="-sS"
	TAR_QUIET=""
fi

# The nightly the game is tested against. Read docs/toolchain.md before
# moving it: `asm` templates are young, and the compiler that parses
# them is still changing under them.
ODIN_NIGHTLY="${ODIN_NIGHTLY:-2026-08-20}"

# Set this instead to take a release archive. A release before
# dev-2026-09 cannot build the game.
ODIN_RELEASE="${ODIN_RELEASE:-}"

NIGHTLY_INDEX="https://odinbinaries.thisdrunkdane.io/file/odin-binaries/nightly.json"

PREFIX="${PREFIX:-/usr/local/bin}"
WORK="${WORK:-$HOME}"

# RAYLIB_DIR is where the bindings look for the library on this arch.
case "$(uname -m)" in
	x86_64)          ARCH=amd64; RAYLIB_DIR=linux ;;
	aarch64 | arm64) ARCH=arm64; RAYLIB_DIR=linux-arm64 ;;
	*) echo "no Odin build for $(uname -m)" >&2; exit 1 ;;
esac

# A step is talk, so it takes the first rung and goes to stderr.
say() { [ "$DEBUG" -ge 1 ] && printf '== %s\n' "$1" >&2 || true; }

say "packages"
apt-get update $APT_QUIET
# clang is the linker Odin calls. libx11-dev is what the static raylib
# links against; raylib loads OpenGL at run time, so no GL package is
# needed to build. make is for the Makefile targets. python3 reads the
# nightly index, which is JSON.
apt-get install -y $APT_QUIET --no-install-recommends \
	clang make curl ca-certificates libx11-dev python3 > "$APT_SINK"

# Say which archive to fetch, as "name<tab>url". A release is named by
# its tag and a nightly by its date, and a name is what the directory
# in $WORK is called, so the two never land on each other.
resolve() {
	if [ -n "$ODIN_RELEASE" ]; then
		printf '%s\t%s\n' "$ODIN_RELEASE" \
			"https://github.com/odin-lang/Odin/releases/download/$ODIN_RELEASE/odin-linux-$ARCH-$ODIN_RELEASE.tar.gz"
		return
	fi
	curl -fL --retry 3 -sS "$NIGHTLY_INDEX" | python3 -c '
import json, sys

want, arch = sys.argv[1], sys.argv[2]
days = json.load(sys.stdin)["files"]
if not days:
    sys.exit("the nightly index is empty")

# The wanted day, or the newest one still kept. A nightly lives about
# eight days, so a checkout older than that asks for a day that has
# gone, and the newest is the honest answer to give it.
day = want if want in days else max(days)
if day != want:
    print(f"nightly {want} is no longer kept; taking {day}", file=sys.stderr)

for f in days[day]:
    if f["name"] == f"odin-linux-{arch}-nightly+{day}.tar.gz":
        print(f"nightly-{day}\t" + f["url"])
        break
else:
    sys.exit(f"the nightly of {day} has no linux-{arch} build")
' "$ODIN_NIGHTLY" "$ARCH"
}

# Once: the index is a download, and it warns on stderr when the day
# asked for has gone.
FOUND=$(resolve)
NAME=$(printf '%s' "$FOUND" | cut -f1)
URL=$(printf '%s' "$FOUND" | cut -f2)
[ -n "$NAME" ] && [ -n "$URL" ] || { echo "no archive to install" >&2; exit 1; }

say "odin $NAME ($ARCH)"
DEST="$WORK/odin-$NAME-$ARCH"
if [ ! -x "$DEST/odin" ]; then
	# Unpack beside the target and move it, so an interrupted download
	# does not leave a half tree that the next run takes for a whole one.
	rm -rf "$DEST.part"
	mkdir -p "$DEST.part"
	curl -fL --retry 3 $CURL_QUIET -o "$DEST.part/odin.tar.gz" "$URL"
	tar xzf $TAR_QUIET "$DEST.part/odin.tar.gz" -C "$DEST.part" --strip-components=1
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

# The game uses `asm` templates. A compiler that cannot parse one fails
# every file that holds one, so say it here rather than in a wall of
# syntax errors.
cat > "$WORK/.odin-asm-probe.odin" <<'PROBE'
package main
zero :: asm() -> (r: u64) {
	xor r, r
}
main :: proc() { _ = zero() }
PROBE
if ! odin build "$WORK/.odin-asm-probe.odin" -file -out:"$WORK/.odin-asm-probe.bin" >/dev/null 2>&1; then
	rm -f "$WORK/.odin-asm-probe.odin" "$WORK/.odin-asm-probe.bin"
	echo "this Odin cannot parse an asm template, so it cannot build the game" >&2
	echo "take a nightly: ODIN_NIGHTLY=latest sudo tools/install-toolchain.sh" >&2
	exit 1
fi
rm -f "$WORK/.odin-asm-probe.odin" "$WORK/.odin-asm-probe.bin"

# The result: what is now on the PATH, and where the tests are run.
printf '%s  %s\n' "✓" "$(odin version)"
say "run the tests from the repository root: tools/test.sh"
