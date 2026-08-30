#!/usr/bin/env python3
"""Paint the Laboratory map: the museum world, one pixel to one region.

    tools/seed_laboratory.py           # draws data/biome_map_laboratory.png
    tools/seed_laboratory.py --check   # holds the file on disk to the rules

The Laboratory is the world one seed opens instead of laying the
ordinary map out again. `[Laboratory]` in data/biomes.txt names the
seed, this picture, and where the wizard starts on it. See
docs/laboratory.md.

The world is three things and nothing else:

  - the physics gallery, at map pixel (9,2), which is world x 512 to
    1023 and y -3072 to -2561
  - the alchemy gallery beside it, at (10,2), world x 1024 to 1535
  - open sky over those two columns and nothing else, so the museum
    stands at the bottom of a cutting in the rock

Where the museum sits in the square is the whole of why it sits there.
The light the game draws with is a square 2048 cells on a side, snapped
to a grid of that size, and world x 0 to 2047 by y -4096 to -2049 is
one of those squares. Everything outside the square the wizard is in is
drawn black, edge and all, so a world laid against that edge shows the
edge. The museum is 1024 by 512 and it is laid in the middle of the
square instead: 512 cells of lit rock west of it, 512 east, 512 under
it, and the cutting over it filling the rest. Nothing the wizard can
walk to, and nothing one tank of fuel can fly to, has the edge of the
square in the frame.

The sky stops where the museum stops for the same reason it is a
cutting: rock in the dark reads as rock, and sky in the dark reads as a
hole in the world.

The two galleries share a row, so their bedrock roofs are one floor
under the sky, and the wizard lands on it between their two doors.
Every gallery cuts its entrance shaft down through the top edge of its
own picture, 4 to 23 cells in from its west side, so on this map the
physics door is at world x 516 to 535 and the alchemy door at x 1028 to
1047: he lands at x 768 and walks about 250 cells either way to reach
one.

The map is the same 16 by 16 as data/biome_map.png, drawn against the
same origin, so a map pixel is a region of 512 world cells here too.

This tool reads data/biomes.txt for the key colors and for the
`[Laboratory]` section, so a biome that changes color is one run away
from a map that agrees with it. It uses no randomness, and draws the
same file byte for byte every time it runs.
"""

import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import noise

from museum import read_sections, write_png, read_png

BIOMES_PATH = "data/biomes.txt"

MAP = 16  # pixels along one edge, the same as data/biome_map.png

SKY_ROWS = 2          # rows 0 and 1 are the cutting over the museum
MUSEUM_ROW = 2        # the row the two galleries sit on
GROUND = "Deep_Rock"  # everything the museum is cut into
SKY = "Sky"

# The halls, west to east along MUSEUM_ROW. Their order is the layout:
# the first one is the one the wizard's own region rule counts to.
HALLS = [(9, "Gallery"), (10, "Alchemy")]


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
    for x, name in HALLS:
        for y in range(SKY_ROWS):
            cells[y][x] = SKY
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

    # Rule 4: everything that is not a hall and not the sky over one is
    # the rock the museum is cut into. The sky stops where the museum
    # stops, so the world and the light square agree; see the header.
    halls = {x for x, _ in HALLS}
    for y in range(height):
        for x in range(width):
            if y == MUSEUM_ROW and x in halls:
                continue
            want = SKY if (y < SKY_ROWS and x in halls) else GROUND
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

    return faults


def names_this_picture(path):
    """Whether [Laboratory] points at the file on disk at all. This is a
    question about the data file rather than about the picture, so it is
    asked of the shipped map and not of a candidate handed to --out: a
    byte-for-byte copy in /tmp is a good map, and holding it to the path
    the section names would make --check and --out useless together."""
    _, laboratory = read_biomes()
    named = laboratory.get("image", "")
    if not named:
        return [f"[Laboratory] names no picture, so nothing opens that world"]
    if os.path.normpath(named) != os.path.normpath(path):
        return [f"[Laboratory] image is {named}, and this is {path}"]
    return []


def main():
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument("--check", action="store_true", help="hold the file on disk to the rules")
    parser.add_argument("--out", default=None)
    noise.add_debug(parser)
    args = parser.parse_args()
    noise.read_debug(args)

    if not os.path.exists(BIOMES_PATH):
        sys.exit(f"cannot read {BIOMES_PATH}; run this from the repository root")

    colors, laboratory = read_biomes()
    out = args.out or laboratory.get("image", "data/biome_map_laboratory.png")
    halls = ", ".join(name for _, name in HALLS)

    if args.check:
        noise.say(noise.STEP, f"checking {out}")
        faults = check(out)
        if args.out is None:
            faults += names_this_picture(out)
        for f in faults:
            noise.fault(f)
        if faults:
            print(f"{noise.CROSS} {out}: {len(faults)} faults")
            sys.exit(1)
        noise.say(noise.DETAIL, f"{out}: {halls} in a cutting under the open sky")
        print(f"{noise.TICK} {out}")
        return

    for name in [SKY, GROUND] + [n for _, n in HALLS]:
        if name not in colors:
            sys.exit(f"{BIOMES_PATH} has no biome named {name}")

    noise.say(noise.STEP, f"painting {halls} into a {MAP}x{MAP} map")
    cells = paint()
    write_png(out, [[rgba(colors[name]) for name in row] for row in cells])
    noise.say(noise.DETAIL, f"{out}: {MAP}x{MAP}, {halls}")
    print(f"{noise.TICK} {out}")


if __name__ == "__main__":
    main()
