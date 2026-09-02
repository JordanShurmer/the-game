#!/usr/bin/env python3
"""Paint the ordinary map: the shipped world, one pixel to one region.

    tools/seed_map.py           # draws data/biome_map.png
    tools/seed_map.py --check   # holds the file on disk to the rules

The map is a 16 by 16 picture and each pixel is a region of 512 world
cells, filled by the biome its color names in data/biomes.txt. ROWS
below is the picture, one letter a region, and this tool draws it.
It uses no randomness and draws the same file every time.

THE RULES IT MUST NOT BREAK

A world that has been through time has already settled. Everything
that could pour, drain or eat its way somewhere has done so, and what
is left rests. The first map was not like that: three rows of sand
stood on a field of oil, a lake stood inside the sand, and a pool of
acid stood on the rock it eats, so from the first tick the whole map
was in motion and never stopped -- see docs/physics.md, "The whole
world". The rules are what "settled" means, and --check holds the
picture on disk to every one of them, so an edit that puts a lake back
in the sand fails here rather than in the tick.

  1. Every pixel is a color some biome in data/biomes.txt claims.
  2. No two touching regions are filled with materials that react.
     Acid eats rock, so acid on Deep_Rock fails; it rests in Bedrock,
     which nothing in the reaction table touches.
  3. A liquid region rests on and beside uniform regions of solid
     fill, or more of itself. A wang region has caves in it, and a
     liquid beside one drains into them; a powder beside one sinks
     through it. What is over a liquid need only be solid, and on
     this map that is rock too: coal is dirt, and dirt is a powder.
  4. A powder region touches no liquid region, on any side. Sand is
     heavier than oil and water and sinks through both, in a column,
     for the life of the world.

Then the two rules the wizard and the reel depend on, which are not
physics: the surface is the six homelands, the cavemouth east of them
and coal east of that, under three rows of sky, and coal under all of
it for three rows. A change there is a change to where he lands and to
the route docs/reel.txt is tuned against.

Read the physics rules as what a region may touch, not as what the
world lacks: the oil, the lake and the acid are all still there, each
in a rock basin, the way an aquifer or a lava chamber is in the earth.
Reaching one is digging.
"""

import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import noise

from museum import read_sections, write_png, read_png

BIOMES_PATH = "data/biomes.txt"
MATERIALS_PATH = "data/materials.txt"

MAP = 16

# One letter a biome. The picture below is the map, north at the top.
LETTERS = {
    ".": "Sky",
    "H": "Homelands",
    "m": "Cavemouth",
    "C": "Coalmine",
    "S": "Sandcave",
    "L": "Lake",
    "O": "Oilfield",
    "A": "Acidpool",
    "M": "Magma",
    "V": "Vault",
    "D": "Deep_Rock",
    "B": "Bedrock",
}

ROWS = [
    "................",
    "................",
    "................",
    "HHHHHHmCCCCCCCCC",
    "CCCCCCCCCCCCCCCC",
    "CCCCCCCCCCCCCCCC",
    "CCCCCCCCCCCCCCCC",
    "SSSSSSSSSSDDDDSS",
    "SSSSSSSSSSDLLDSS",
    "SSSSSSSSSSDDDDSS",
    "DDDDDDDDDDDDDDDD",
    "OOBBBBOOOOOOOOOO",
    "OOBAABOOOOOOOOOO",
    "DDBBBBDDDDDDDVDD",
    "DDDDDDMMMMDDDDDD",
    "DDDDDDMMMMDDDDDD",
]

SURFACE_ROWS = ROWS[:7]


def read_biomes(path=BIOMES_PATH):
    """Biome name to (ARGB color, generator, fill material)."""
    biomes = {}
    for name, fields in read_sections(path).items():
        if name in ("Map", "Laboratory"):
            continue
        biomes[name] = (
            int(fields["color"], 0),
            fields.get("generator", "uniform"),
            fields["fill_0"],
        )
    return biomes


def read_materials(path=MATERIALS_PATH):
    """Material name to state, and the set of pairs that react."""
    sections = read_sections(path)
    states = {name: f.get("state", "Solid") for name, f in sections.items() if name != "Reactions"}
    pairs = set()
    for line in open(path, encoding="utf-8"):
        line = line.split("#", 1)[0].strip()
        if "->" not in line:
            continue
        left = line.split("->", 1)[0]
        a, b = (part.strip() for part in left.split("+", 1))
        pairs.add((a, b))
        pairs.add((b, a))
    return states, pairs


def paint():
    return [[LETTERS[ch] for ch in row] for row in ROWS]


def rgba(argb):
    return ((argb >> 16) & 0xFF, (argb >> 8) & 0xFF, argb & 0xFF, (argb >> 24) & 0xFF)


def neighbours(x, y):
    for nx, ny, where in ((x, y + 1, "under"), (x - 1, y, "beside"), (x + 1, y, "beside"), (x, y - 1, "over")):
        if 0 <= nx < MAP and 0 <= ny < MAP:
            yield nx, ny, where


def check(path):
    faults = []
    if not os.path.exists(path):
        return [f"{path} does not exist; run this tool with no arguments"]

    biomes = read_biomes()
    by_color = {argb: name for name, (argb, _, _) in biomes.items()}
    states, reacts = read_materials()

    width, height, rows = read_png(path)
    if (width, height) != (MAP, MAP):
        return [f"{path} is {width}x{height}, and the map must be {MAP}x{MAP}"]

    # Rule 1: every pixel is a color some biome claims.
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

    def fill(x, y):
        return biomes[names[y][x]][2]

    def state(x, y):
        return states.get(fill(x, y), "Solid")

    def uniform(x, y):
        return biomes[names[y][x]][1] == "uniform"

    for y in range(MAP):
        for x in range(MAP):
            here = names[y][x]
            for nx, ny, where in neighbours(x, y):
                there = names[ny][nx]
                if there == here:
                    continue
                # Rule 2: nothing eats its neighbour.
                if (fill(x, y), fill(nx, ny)) in reacts:
                    faults.append(
                        f"pixel ({x},{y}) {here} is {fill(x, y)} and {where} it ({nx},{ny}) {there} "
                        f"is {fill(nx, ny)}, and the two react"
                    )
                # Rule 3: a liquid rests on and beside solid uniform ground.
                if state(x, y) == "Liquid":
                    if state(nx, ny) != "Solid":
                        faults.append(
                            f"pixel ({x},{y}) {here} is liquid and {where} it ({nx},{ny}) {there} "
                            f"is {fill(nx, ny)}, which is not solid"
                        )
                    elif where != "over" and not uniform(nx, ny):
                        faults.append(
                            f"pixel ({x},{y}) {here} is liquid and {where} it ({nx},{ny}) {there} "
                            f"has caves for it to drain into"
                        )
                # Rule 4: a powder touches no liquid.
                if state(x, y) == "Powder" and state(nx, ny) == "Liquid":
                    faults.append(
                        f"pixel ({x},{y}) {here} is powder and {where} it ({nx},{ny}) {there} "
                        f"is liquid, which it sinks through"
                    )

    # The surface: where he lands, and the route the reel is tuned to.
    for y, row in enumerate(SURFACE_ROWS):
        for x, ch in enumerate(row):
            if names[y][x] != LETTERS[ch]:
                faults.append(f"pixel ({x},{y}) is {names[y][x]}, and the surface wants {LETTERS[ch]}")

    return sorted(set(faults))


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

    sections = read_sections(BIOMES_PATH)
    out = args.out or sections.get("Map", {}).get("image", "data/biome_map.png")

    if args.check:
        noise.say(noise.STEP, f"checking {out}")
        faults = check(out)
        for f in faults:
            noise.fault(f)
        if faults:
            print(f"{noise.CROSS} {out}: {len(faults)} faults")
            sys.exit(1)
        print(f"{noise.TICK} {out}")
        return

    biomes = read_biomes()
    for name in LETTERS.values():
        if name not in biomes:
            sys.exit(f"{BIOMES_PATH} has no biome named {name}")

    noise.say(noise.STEP, f"painting a {MAP}x{MAP} map")
    cells = paint()
    write_png(out, [[rgba(biomes[name][0]) for name in row] for row in cells])
    print(f"{noise.TICK} {out}")


if __name__ == "__main__":
    main()
