#!/usr/bin/env sh
# Run the suite and say how it went in as little as it takes.
#
#   tools/test.sh            a mark for each test, then the count
#   tools/test.sh -v         the name beside each mark
#   tools/test.sh -vv        what the Odin test runner itself prints
#   tools/test.sh -vvv       everything, the graphics trace log included
#   tools/test.sh NAME ...   only the tests whose names hold NAME
#
# A passing run is a block of ticks and one line of count. A failing
# run is the same block with crosses in it, and then the failures:
# the message, and the file and line it came from.
#
# `odin test src` still works and prints what it always did. This
# script is the quiet front for it, and `make test` runs it.
set -eu

DEBUG=0
NAMES=""
PATTERNS=""

usage() {
	sed -n '2,15p' "$0" | cut -c3-
	exit "${1:-1}"
}

for arg in "$@"; do
	case "$arg" in
		-h | --help) usage 0 ;;
		-v)   DEBUG=1 ;;
		-vv)  DEBUG=2 ;;
		-vvv) DEBUG=3 ;;
		-d[0-3]) DEBUG=${arg#-d} ;;
		-*) echo "there is no option $arg" >&2; usage ;;
		*) PATTERNS="$PATTERNS $arg" ;;
	esac
done

[ -f src/main.odin ] || { echo "run this from the repository root" >&2; exit 1; }

# The runner selects a test by its whole name. A reader knows a piece
# of one, so the pieces are grown into whole names here, off the
# declarations in the source.
if [ -n "$PATTERNS" ]; then
	ALL=$(grep -h -A1 '^@(test)' src/*.odin | sed -n 's/^\([a-zA-Z0-9_]*\) *:: *proc.*/\1/p')
	for pattern in $PATTERNS; do
		hits=$(printf '%s\n' "$ALL" | grep -F -- "$pattern" || true)
		if [ -z "$hits" ]; then
			echo "no test name holds $pattern" >&2
			exit 1
		fi
		for hit in $hits; do NAMES="$NAMES$hit,"; done
	done
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# GAME_DEBUG is the same ladder the game and its tools read, so the
# rung asked for here reaches the graphics log and the loaders too.
export GAME_DEBUG="$DEBUG"

set -- odin test src -out:"$WORK/suite.bin"
[ -n "$NAMES" ] && set -- "$@" -define:ODIN_TEST_NAMES="$NAMES"

if [ "$DEBUG" -ge 2 ]; then
	exec "$@"
fi

# Below the second rung the runner's own output is captured, and this
# script prints the marks instead. The report says which tests ran and
# how each ended; the captured text holds the failure messages, which
# already carry their file and line.
set -- "$@" -define:ODIN_TEST_FANCY=false -define:ODIN_TEST_JSON_REPORT="$WORK/report.json"

STATUS=0
"$@" > "$WORK/runner.log" 2>&1 || STATUS=$?

if [ ! -f "$WORK/report.json" ]; then
	# No report means the suite never ran: it did not compile, or it
	# died before the end. That output is the only useful thing here.
	cat "$WORK/runner.log" >&2
	exit "${STATUS:-1}"
fi

DEBUG="$DEBUG" python3 tools/test_report.py "$WORK/report.json" "$WORK/runner.log"
