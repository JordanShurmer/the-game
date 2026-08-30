#!/usr/bin/env python3
"""Paint the Laboratory map: the museum world, one pixel to one region.

    tools/seed_laboratory.py           # draws data/biome_map_laboratory.png
    tools/seed_laboratory.py --check   # holds the file on disk to the rules

The Laboratory is the world one seed opens instead of laying the
ordinary map out again. `[Laboratory]` in data/biomes.txt names the
seed, this picture, and where the wizard starts on it. See
docs/laboratory.md.

The world is three things and nothing else:

  - the physics gallery, at map pixel (8,3), which is world x 0 to 511
  - the alchemy gallery beside it, at (9,3), world x 512 to 1023
  - open sky over both, and rock everywhere else

The two galleries share a row, so their bedrock roofs are one floor
under the sky, and the wizard lands on it between their two doors.
Every gallery cuts its entrance shaft down through the top edge of its
own picture, 4 to 24 cells in from its west side, so on this map the
physics door is at world x 4 and the alchemy door at x 516: he walks
about 250 cells either way to reach one.

The map is the same 16 by 16 as data/biome_map.png, drawn against the
same origin, so a room of a gallery keeps the world coordinates every
note already gives for it.

This tool reads data/biomes.txt for the key colors and for the
`[Laboratory]` section, so a biome that changes color is one run away
from a map that agrees with it. It uses no randomness, and draws the
same file byte for byte every time it runs.
"""

import argparse
import os
import sys

from museum import read_sections, write_png, read_png

BIOMES_PATH = "data/biomes.txt"

MAP = 16  # pixels along one edge, the same as data/biome_map.png

SKY_ROWS = 3          # rows 0 to 2 are open sky
MUSEUM_ROW = 3        # the row the two galleries sit on
GROUND = "Deep_Rock"  # everything the museum is sunk in
SKY = "Sky"

# The halls, west to east along MUSEUM_ROW. Their order is the layout:
# the first one is the one the wizard's own region rule counts to.
HALLS = [(8, "Gallery"), (9, "Alchemy")]


def read_biomes(path=BIOMES_PATH):
    """Biome name to ARGB key color, and the [Laboratory] section, from
    the one file that defines both."""
    sections = read_sections(path)
    laboratory = sections.get("Laboratory", {})
    colors = {
        name: int(fields["color"], 0)
        for name, fields in sections.items()
        if name not in ("Map", "Laboratory") and "color" in fields
    }
    return colors, laboratory


def paint():
    """The map as a grid of biome names, addressed [y][x]."""
    cells = [[GROUND] * MAP for _ in range(MAP)]
    for y in range(SKY_ROWS):
        for x in range(MAP):
            cells[y][x] = SKY
    for x, name in HALLS:
        cells[MUSEUM_ROW][x] = name
    return cells


def rgba(argb):
    return ((argb >> 16) & 0xFF, (argb >> 8) & 0xFF, argb & 0xFF, (argb >> 24) & 0xFF)


def check(path):
    faults = []
    if not os.path.exists(path):
        return [f"{path} does not exist; run this tool with no arguments"]

    colors, laboratory = read_biomes()
    by_color = {argb: name for name, argb in colors.items()}

    width, height, rows = read_png(path)
    if (width, height) != (MAP, MAP):
        return [f"{path} is {width}x{height}, and the map must be {MAP}x{MAP}"]

    # Rule 1: every pixel is a color some biome in data/biomes.txt claims.
    names = [[None] * width for _ in range(height)]
    for y in range(height):
        for x in range(width):
            r, g, b, a = rows[y][x]
            argb = (a << 24) | (r << 16) | (g << 8) | b
            names[y][x] = by_color.get(argb)
            if names[y][x] is None:
                faults.append(f"pixel ({x},{y}) is color {argb:08X}, which no biome claims")
    if faults:
        return faults

    # Rule 2: the halls sit side by side on one row, so their roofs join.
    for x, name in HALLS:
        if names[MUSEUM_ROW][x] != name:
            faults.append(f"pixel ({x},{MUSEUM_ROW}) is {names[MUSEUM_ROW][x]}, not {name}")
    for (x, name), (nx, next_name) in zip(HALLS, HALLS[1:]):
        if nx != x + 1:
            faults.append(f"{name} and {next_name} are not side by side, so their roofs do not join")

    # Rule 3: open sky the whole way up over every hall, so the roof is
    # under the day and the day lights it.
    for x, name in HALLS:
        for y in range(MUSEUM_ROW):
            if names[y][x] != SKY:
                faults.append(f"pixel ({x},{y}) over {name} is {names[y][x]}, not {SKY}")

    # Rule 4: everything that is not a hall and not sky is the ground
    # the museum is sunk in.
    halls = {x for x, _ in HALLS}
    for y in range(height):
        for x in range(width):
            if y < SKY_ROWS:
                want = SKY
            elif y == MUSEUM_ROW and x in halls:
                continue
            else:
                want = GROUND
            if names[y][x] != want:
                faults.append(f"pixel ({x},{y}) is {names[y][x]}, and it must be {want}")

    # Rule 5: the spawn [Laboratory] names is one of the halls, and the
    # region it counts to exists on this picture.
    spawn = laboratory.get("spawn_biome", "")
    region = int(laboratory.get("spawn_region", "1"))
    if spawn not in dict((name, x) for x, name in HALLS).keys():
        faults.append(f"[Laboratory] spawn_biome is {spawn!r}, which is not a hall of this map")
    else:
        seen = sum(
            1
            for y in range(height)
            for x in range(width)
            if names[y][x] == spawn
        )
        if region < 1 or region > seen:
            faults.append(
                f"[Laboratory] spawn_region is {region}, and this map draws {seen} "
                f"region(s) of {spawn}"
            )

    # Rule 6: the picture is the one [Laboratory] names.
    named = laboratory.get("image", "")
    if named and os.path.normpath(named) != os.path.normpath(path):
        faults.append(f"[Laboratory] image is {named}, and this is {path}")

    return faults


def main():
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument("--check", action="store_true", help="hold the file on disk to the rules")
    parser.add_argument("--out", default=None)
    args = parser.parse_args()

    if not os.path.exists(BIOMES_PATH):
        sys.exit(f"cannot read {BIOMES_PATH}; run this from the repository root")

    colors, laboratory = read_biomes()
    out = args.out or laboratory.get("image", "data/biome_map_laboratory.png")

    if args.check:
        faults = check(out)
        for fault in faults:
            print(fault, file=sys.stderr)
        if faults:
            sys.exit(1)
        halls = ", ".join(name for _, name in HALLS)
        print(f"{out}: {MAP}x{MAP}, {halls} under the open sky, every rule holds")
        return

    for name in [SKY, GROUND] + [n for _, n in HALLS]:
        if name not in colors:
            sys.exit(f"{BIOMES_PATH} has no biome named {name}")

    cells = paint()
    write_png(out, [[rgba(colors[name]) for name in row] for row in cells])
    print(f"{out}: {MAP}x{MAP}, " + ", ".join(name for _, name in HALLS))


if __name__ == "__main__":
    main()
