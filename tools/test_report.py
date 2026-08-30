#!/usr/bin/env python3
"""Turn a test run into marks.

tools/test.sh runs the suite and hands this script two files: the JSON
report, which says which tests ran and how each ended, and the text the
Odin test runner wrote, which holds the message of each failure and the
file and line it came from.

Rung 0 prints a block of marks and one line of count. Rung 1 prints the
name beside each mark. A failure prints in full at either rung, after
the block, because a reader who has a cross wants the reason and not
the shape of the run.
"""

import json
import os
import re
import shutil
import sys

TICK = "✓"
CROSS = "✗"

# [ERROR] --- [2026-08-30 16:00:53] [main.odin:412:test_name()] the message
FAULT = re.compile(r"^\[(ERROR|FATAL)\s*\].*?\[([^\[\]]+?):(\d+):([A-Za-z0-9_]+)\(\)\]\s*(.*)$")


def faults(log_path):
    """The message, file and line of each test that failed, by test name."""
    found = {}
    try:
        text = open(log_path, encoding="utf-8", errors="replace").read()
    except OSError:
        return found

    for line in text.splitlines():
        hit = FAULT.match(line)
        if hit is None:
            continue
        _, file, line_no, name, message = hit.groups()
        # A test can fail more than once. The first is the one that
        # broke it; the rest are what broke after.
        found.setdefault(name, []).append((file, int(line_no), message))
    return found


def main():
    if len(sys.argv) != 3:
        sys.exit("usage: test_report.py report.json runner.log")

    report = json.load(open(sys.argv[1], encoding="utf-8"))
    reasons = faults(sys.argv[2])
    rung = int(os.environ.get("DEBUG", "0"))

    tests = []
    for package in sorted(report.get("packages", {})):
        for test in report["packages"][package]:
            tests.append((test["name"], test["success"]))
    tests.sort()

    if rung >= 1:
        for name, ok in tests:
            print(f"{TICK if ok else CROSS} {name}")
    else:
        # As wide as the terminal, so the block is a shape a reader
        # takes in at once rather than a list to scroll.
        width = max(shutil.get_terminal_size((80, 24)).columns - 1, 16)
        marks = "".join(TICK if ok else CROSS for _, ok in tests)
        for i in range(0, len(marks), width):
            print(marks[i:i + width])

    failed = [name for name, ok in tests if not ok]
    for name in failed:
        print()
        print(f"{CROSS} {name}")
        for file, line_no, message in reasons.get(name, [("?", 0, "no message")]):
            print(f"  {file}:{line_no}: {message}")

    total = report.get("total", len(tests))
    success = report.get("success", total - len(failed))
    seconds = report.get("duration", 0) / 1e9

    print()
    if failed:
        print(f"{CROSS} {len(failed)} of {total} failed in {seconds:.1f}s")
        return 1
    print(f"{TICK} {success}/{total} in {seconds:.1f}s")
    return 0


if __name__ == "__main__":
    sys.exit(main())
