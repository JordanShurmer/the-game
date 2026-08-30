"""How loud a tool is.

The same ladder the rest of the toolset reads, in the shape argparse
wants. See src/noise.odin for the ladder itself:

    0  the result, and nothing else            (the default)
    1  a line for each piece of work
    2  the detail behind each line
    3  everything

A tool adds the flags with `add_debug(parser)` and then says things
with `say(rung, ...)`. A result is not talk: it goes to stdout with no
rung, so a shell can keep it and drop the rest.
"""

import os
import sys

RESULT = 0
STEP = 1
DETAIL = 2
TRACE = 3

TICK = "✓"
CROSS = "✗"

ENV = "GAME_DEBUG"

_rung = 0


def add_debug(parser):
    """The -v flags every tool in tools/ takes."""
    parser.add_argument(
        "-v", "--debug", action="count", default=None,
        help="say more; -vv and -vvv say more again",
    )
    return parser


def read_debug(args):
    """Settle the rung from the command line, or the environment when
    the command line says nothing."""
    global _rung
    if getattr(args, "debug", None) is not None:
        _rung = min(args.debug, TRACE)
    else:
        try:
            _rung = min(max(int(os.environ.get(ENV, "0")), RESULT), TRACE)
        except ValueError:
            _rung = RESULT
    return _rung


def level():
    return _rung


def say(rung, message):
    """A line that only a run asking for that rung sees."""
    if _rung >= rung:
        print(message, file=sys.stderr)


def fault(message):
    """Something went wrong. A fault prints at every rung."""
    print(message, file=sys.stderr)
