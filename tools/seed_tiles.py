#!/usr/bin/env python3
"""Seed the Wang tile set of a biome: a cave system, roughly half air.

The tiles in data/tiles are authored data. This draws a first set for a
biome that has none, or draws a new one when the feel of a biome
changes and hand editing 32 pictures is not the way. Small changes
belong in the tile editor, which keeps the seam rule for you.

    tools/seed_tiles.py --list
    tools/seed_tiles.py Coalmine --force        # OVERWRITES its tiles
    tools/seed_tiles.py --check                 # verify what is on disk

It reads data/materials.txt and data/biomes.txt, so a biome only has to
exist there to be seeded. Run it from the repository root.

WHAT IT DRAWS

A tile starts solid and the caves are cut out of it. Carving from stone
gives what a cave system has, which is space inside a mass; smoothing
noise gives the opposite, a void with islands of matter floating in it.
Each tile has a hall, passages out to every open side that bend at a
waypoint on the way, chambers off the hall, and dead ends.

THE RULE IT MUST NOT BREAK

The game only ever puts two tiles side by side when they agree about
the edge between them, and the WANG_SEAM cells along each side belong
to the edge color rather than to the tile. So:

  - every tile that carries color c on its west side holds the same
    four columns there, and the same for the other three sides
  - a corner cell is in two bands at once, so the whole set shares it
  - the material of a band cell may only depend on that band. A speckle
    or a wider rim drawn at random stops at the band and traces the
    lattice across the whole world.

--check reads the files back and holds them to that rule, which is the
same gate the editor puts on a save.

ADDING A BIOME

Give it `generator = wang` and a `tiles` prefix in data/biomes.txt, add
a line to STYLES below if the default palette is wrong for it, then run
this. The set starts as flat fill until something draws it, so a biome
with no entry here still works; it just looks like nothing.
"""

import argparse
import os
import random
import struct
import sys
import zlib

TILE = 64
SEAM = 4

SOLID, OPEN = 1, 0

AIR = (0, 0, 0, 0)

# The passage that crosses an open edge, and the sizes the carve works
# at. Widen these to open a biome up; the world reads as scratches in
# ground below about a third air and as a hall with pillars above two
# thirds. src/tile_png.odin holds a test at the same numbers.
MOUTH_LO, MOUTH_HI = 22, 41
MOUTH_DEPTH = 8
HUB_R = (10, 14)
TRUNK_R = (8, 11)

MATERIALS_PATH = "data/materials.txt"
BIOMES_PATH = "data/biomes.txt"

# How a biome is made of its materials. `base` is the fill material the
# biome already names in data/biomes.txt, so only the rest is here.
# `seed` fixes the drawing: the same seed gives the same set forever.
DEFAULT_STYLE = {"rock": "Rock", "ore": "Gold", "ore_rate": 0.3, "seed": None}

STYLES = {
    "Coalmine": {"rock": "Rock", "ore": "Gold", "ore_rate": 0.5, "seed": 0x5EED},
    "Sandcave": {"rock": "Rock", "ore": "Gold", "ore_rate": 0.2, "seed": 0xCA7E},
}


# ------------------------------------------------------------ the data files


def read_sections(path):
    """The format materials.txt and biomes.txt share: [Name] and key = value."""
    sections, name = {}, None
    for line in open(path, encoding="utf-8"):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("[") and line.endswith("]"):
            name = line[1:-1]
            sections[name] = {}
            continue
        if "=" not in line or name is None:
            continue
        key, value = line.split("=", 1)
        value = value.split("#", 1)[0].strip()
        sections[name][key.strip()] = value
    return sections


def read_materials():
    """Material name to RGBA, from the one file that defines them."""
    colors = {}
    for name, fields in read_sections(MATERIALS_PATH).items():
        argb = int(fields.get("color", "0"), 0)
        colors[name] = (
            (argb >> 16) & 0xFF,
            (argb >> 8) & 0xFF,
            argb & 0xFF,
            (argb >> 24) & 0xFF,
        )
    return colors


def read_biomes():
    """Every biome that draws a tile set, with what it needs to be drawn."""
    biomes = {}
    for name, fields in read_sections(BIOMES_PATH).items():
        if name == "Map" or fields.get("generator") != "wang":
            continue
        biomes[name] = {
            "prefix": fields["tiles"],
            "variants": int(fields.get("variants", 1)),
            "fill": fields["fill_0"],
        }
    return biomes


def style_of(name):
    style = dict(DEFAULT_STYLE)
    style.update(STYLES.get(name, {}))
    if style["seed"] is None:
        # A stable seed for a biome nobody has given one. Python hashes
        # strings differently in every process, so it must not be hash().
        style["seed"] = zlib.crc32(name.encode()) & 0xFFFF
    return style


# ------------------------------------------------------------------- the PNG


def write_png(path, pix):
    raw = b"".join(
        b"\x00" + b"".join(struct.pack("BBBB", *pix[y][x]) for x in range(TILE))
        for y in range(TILE)
    )

    def chunk(tag, data):
        body = tag + data
        return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)

    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", TILE, TILE, 8, 6, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(raw, 9))
    png += chunk(b"IEND", b"")
    open(path, "wb").write(png)


def read_png(path):
    """Read a tile back. --check has to read what the editor wrote as
    well as what this wrote, and the two use different scanline filters,
    so every filter is handled."""
    data = open(path, "rb").read()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError(f"{path} is not a PNG")

    idat, width, height, i = b"", 0, 0, 8
    while i < len(data):
        length = struct.unpack(">I", data[i : i + 4])[0]
        tag = data[i + 4 : i + 8]
        body = data[i + 8 : i + 8 + length]
        i += 12 + length
        if tag == b"IHDR":
            width, height, depth, color = struct.unpack(">IIBB", body[:10])
            if (width, height, depth, color) != (TILE, TILE, 8, 6):
                raise ValueError(f"{path} is {width}x{height}, not a {TILE} square RGBA tile")
        elif tag == b"IDAT":
            idat += body

    raw = zlib.decompress(idat)
    stride = TILE * 4
    rows, previous, at = [], bytearray(stride), 0
    for _ in range(TILE):
        filter_kind, at = raw[at], at + 1
        line = bytearray(raw[at : at + stride])
        at += stride
        for x in range(stride):
            a = line[x - 4] if x >= 4 else 0
            b = previous[x]
            c = previous[x - 4] if x >= 4 else 0
            if filter_kind == 1:
                line[x] = (line[x] + a) & 0xFF
            elif filter_kind == 2:
                line[x] = (line[x] + b) & 0xFF
            elif filter_kind == 3:
                line[x] = (line[x] + (a + b) // 2) & 0xFF
            elif filter_kind == 4:
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                near = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                line[x] = (line[x] + near) & 0xFF
            elif filter_kind != 0:
                raise ValueError(f"{path} uses scanline filter {filter_kind}")
        rows.append([tuple(line[x * 4 : x * 4 + 4]) for x in range(TILE)])
        previous = line
    return rows


# ---------------------------------------------------------------- the carving


def band_of(x, y):
    """Which band a cell is in, or None for the free middle."""
    across = "W" if x < SEAM else ("E" if x >= TILE - SEAM else None)
    down = "N" if y < SEAM else ("S" if y >= TILE - SEAM else None)
    if across and down:
        return "C"
    return across or down


def carve_disc(grid, cx, cy, r):
    for y in range(max(0, cy - r), min(TILE, cy + r + 1)):
        for x in range(max(0, cx - r), min(TILE, cx + r + 1)):
            if (x - cx) ** 2 + (y - cy) ** 2 <= r * r:
                grid[y][x] = OPEN


def carve_disc_solid(grid, cx, cy, r):
    for y in range(max(0, cy - r), min(TILE, cy + r + 1)):
        for x in range(max(0, cx - r), min(TILE, cx + r + 1)):
            if (x - cx) ** 2 + (y - cy) ** 2 <= r * r:
                grid[y][x] = SOLID


def carve_walk(grid, x0, y0, x1, y1, r, rng, wobble=0.55):
    """A passage from one place to another, cut the way water cuts one.

    It leans toward where it is going and is pushed sideways at every
    step, and its width drifts, so it comes out with throats and
    galleries in it rather than one straight bore.
    """
    x, y = float(x0), float(y0)
    radius = float(r)

    for _ in range(400):
        dx, dy = x1 - x, y1 - y
        distance = max(1e-6, (dx * dx + dy * dy) ** 0.5)
        if distance <= 1.5:
            break
        dx, dy = dx / distance, dy / distance

        swing = rng.uniform(-wobble, wobble)
        x += dx - dy * swing
        y += dy + dx * swing
        radius = min(r + 2, max(3.0, radius + rng.uniform(-0.9, 0.9)))
        carve_disc(grid, round(x), round(y), int(radius))

    carve_disc(grid, x1, y1, int(radius))


def ragged(grid, rng, passes=2, open_p=0.45, close_p=0.30):
    """Roughen the walls a carve left behind.

    A disc has a smooth edge and a cave does not. This opens matter
    that already has air on several sides and closes air that is nearly
    surrounded, which frees the walls of arcs and fills in pinholes.
    """
    for _ in range(passes):
        out = [row[:] for row in grid]
        for y in range(1, TILE - 1):
            for x in range(1, TILE - 1):
                n = sum(
                    1
                    for dy in (-1, 0, 1)
                    for dx in (-1, 0, 1)
                    if not (dx == 0 and dy == 0) and grid[y + dy][x + dx] == OPEN
                )
                if grid[y][x] == SOLID and n >= 3 and rng.random() < open_p:
                    out[y][x] = OPEN
                elif grid[y][x] == OPEN and n <= 2 and rng.random() < close_p:
                    out[y][x] = SOLID
        grid = out
    return grid


def apron(grid, sig, rng):
    """Thicken the mass behind a wall by a wandering amount.

    A band is the same four cells in every tile that carries its edge
    color, so a cave carved up to one comes out with a wall face that is
    straight and always the same distance from the border. The apron
    sits inside the tile, where every tile is free to differ, and gives
    that face a thickness that wanders instead.
    """
    n, e, s, w = sig
    for side, color in (("N", n), ("E", e), ("S", s), ("W", w)):
        thickness = rng.randint(0, 4)
        for along in range(TILE):
            thickness = min(5, max(0, thickness + rng.randint(-1, 1)))
            # A mouth must stay a mouth; the apron is for the wall
            # either side of it.
            if color == 1 and MOUTH_LO - 1 <= along <= MOUTH_HI + 1:
                continue

            for depth in range(SEAM, SEAM + thickness):
                if side == "W":
                    grid[along][depth] = SOLID
                elif side == "E":
                    grid[along][TILE - 1 - depth] = SOLID
                elif side == "N":
                    grid[depth][along] = SOLID
                else:
                    grid[TILE - 1 - depth][along] = SOLID


def carve_interior(sig, rng):
    """A tile starts solid, and the caves are cut out of it.

    A passage never runs straight from a mouth to the middle. It bends
    at a waypoint on the way, because a lattice of tiles whose passages
    all run to the centre reads as a cross in every square.
    """
    n, e, s, w = sig
    grid = [[SOLID] * TILE for _ in range(TILE)]

    # The hall the passages meet at, off centre so the tile has no axis.
    mid = (MOUTH_LO + MOUTH_HI) // 2
    hx = mid + rng.randint(-8, 8)
    hy = mid + rng.randint(-8, 8)
    carve_disc(grid, hx, hy, rng.randint(*HUB_R))

    open_sides = [side for side, color in (("N", n), ("E", e), ("S", s), ("W", w)) if color == 1]
    for side in open_sides:
        end = {"N": (mid, 0), "S": (mid, TILE - 1), "W": (0, mid), "E": (TILE - 1, mid)}[side]

        # A place to bend at, part of the way in and off to one side.
        wx = round(end[0] + (hx - end[0]) * 0.45) + rng.randint(-10, 10)
        wy = round(end[1] + (hy - end[1]) * 0.45) + rng.randint(-10, 10)
        wx = min(TILE - SEAM - 3, max(SEAM + 3, wx))
        wy = min(TILE - SEAM - 3, max(SEAM + 3, wy))

        carve_walk(grid, end[0], end[1], wx, wy, rng.randint(6, 8), rng, wobble=0.5)
        if rng.random() < 0.6:
            carve_disc(grid, wx, wy, rng.randint(6, 9))
        carve_walk(grid, wx, wy, hx, hy, rng.randint(5, 8), rng, wobble=0.8)

        # The mouth stays the full width the band promises, so the
        # passage across the border does not pinch.
        if side in "WE":
            x0 = 0 if side == "W" else TILE - MOUTH_DEPTH
            for y in range(MOUTH_LO, MOUTH_HI + 1):
                for x in range(x0, x0 + MOUTH_DEPTH):
                    grid[y][x] = OPEN
        else:
            y0 = 0 if side == "N" else TILE - MOUTH_DEPTH
            for x in range(MOUTH_LO, MOUTH_HI + 1):
                for y in range(y0, y0 + MOUTH_DEPTH):
                    grid[y][x] = OPEN

    # Chambers off the hall, so a tile is a place and not a junction.
    for _ in range(rng.randint(3, 4)):
        cx = rng.randrange(SEAM + 5, TILE - SEAM - 5)
        cy = rng.randrange(SEAM + 5, TILE - SEAM - 5)
        carve_walk(grid, hx, hy, cx, cy, rng.randint(4, 6), rng, wobble=0.9)
        carve_disc(grid, cx, cy, rng.randint(8, 12))

    # Dead ends: somewhere to explore that does not lead on.
    for _ in range(rng.randint(1, 2)):
        ax = rng.randrange(SEAM + 4, TILE - SEAM - 4)
        ay = rng.randrange(SEAM + 4, TILE - SEAM - 4)
        carve_walk(grid, hx, hy, ax, ay, rng.randint(3, 4), rng, wobble=1.0)

    apron(grid, sig, rng)
    grid = ragged(grid, rng)

    # Pillars, where a chamber came out wide enough to hold one.
    for _ in range(3):
        px = rng.randrange(SEAM + 8, TILE - SEAM - 8)
        py = rng.randrange(SEAM + 8, TILE - SEAM - 8)
        clear = all(
            grid[py + dy][px + dx] == OPEN for dy in range(-7, 8) for dx in range(-7, 8)
        )
        if not clear:
            continue
        # two lumps, so a pillar is not a circle
        carve_disc_solid(grid, px, py, rng.randint(3, 4))
        carve_disc_solid(
            grid, px + rng.randint(-3, 3), py + rng.randint(-3, 3), rng.randint(2, 3)
        )
    return grid


# ------------------------------------------------------------------ the bands


def band_profile(color, rng):
    """One border band, as a [SEAM][TILE] grid of SOLID and OPEN.

    It depends on the side and the color only, so every tile that
    carries that color holds the same band.
    """
    band = [[SOLID] * TILE for _ in range(SEAM)]
    if color == 0:
        return band

    # A jagged mouth: the opening is the same width everywhere, and its
    # lip is ragged, so a border does not read as a doorway.
    for depth in range(SEAM):
        lo = MOUTH_LO + rng.randint(0, 2)
        hi = MOUTH_HI - rng.randint(0, 2)
        for along in range(lo, hi + 1):
            band[depth][along] = OPEN
    return band


def band_materials(band, base, rock, wall=2):
    """The materials of one band, from the band alone.

    It may not look at the interior of any tile: two tiles that share
    this band draw different caves behind it, and a material that
    depended on those would differ between them. So the rock face is
    the lip of the mouth, and the rest is the body of the mass.
    """
    out = [[base] * TILE for _ in range(SEAM)]
    for depth in range(SEAM):
        for along in range(TILE):
            if band[depth][along] == OPEN:
                out[depth][along] = AIR
                continue
            near = False
            for dd in range(-wall, wall + 1):
                for da in range(-wall, wall + 1):
                    d, a = depth + dd, along + da
                    if d < 0 or a < 0 or d >= SEAM or a >= TILE:
                        continue
                    if band[d][a] == OPEN:
                        near = True
            out[depth][along] = rock if near else base
    return out


def stamp(target, sig, profiles, corner):
    """Write the four bands over a tile, then the corners.

    `target` is a solid/open grid or a material grid, and `profiles`
    holds the matching kind. Both are stamped, because both have to be
    the same in every tile that carries the edge color.
    """
    n, e, s, w = sig
    for depth in range(SEAM):
        for along in range(TILE):
            target[along][depth] = profiles[("W", w)][depth][along]
            target[along][TILE - 1 - depth] = profiles[("E", e)][depth][along]
            target[depth][along] = profiles[("N", n)][depth][along]
            target[TILE - 1 - depth][along] = profiles[("S", s)][depth][along]
    # A corner is in two bands at once, so the whole set shares it.
    for y in range(TILE):
        for x in range(TILE):
            if band_of(x, y) == "C":
                target[y][x] = corner


# --------------------------------------------------------------- the material


def to_materials(grid, base, rock, ore, ore_rate, rng, wall=2):
    """Rock where the mass meets air, the base material deeper in.

    The rule may only ask how near a cell is to air, because the band
    cells follow the same rule with only their own four rows to look at.
    Anything else here, a speckle or a wider rim drawn at random, would
    stop at the band and trace the lattice across the world.
    """
    pix = [[base] * TILE for _ in range(TILE)]
    for y in range(TILE):
        for x in range(TILE):
            if grid[y][x] == OPEN:
                pix[y][x] = AIR
                continue
            near = False
            for dy in range(-wall, wall + 1):
                for dx in range(-wall, wall + 1):
                    px, py = x + dx, y + dy
                    if px < 0 or py < 0 or px >= TILE or py >= TILE:
                        continue
                    if grid[py][px] == OPEN:
                        near = True
            pix[y][x] = rock if near else base

    # Ore in veins, not confetti: a few seeds that crawl through rock.
    for _ in range(int(ore_rate * 14)):
        x, y = rng.randrange(SEAM, TILE - SEAM), rng.randrange(SEAM, TILE - SEAM)
        for _ in range(rng.randint(3, 9)):
            if band_of(x, y) is None and pix[y][x] == rock:
                pix[y][x] = ore
            x = min(TILE - 1, max(0, x + rng.randint(-1, 1)))
            y = min(TILE - 1, max(0, y + rng.randint(-1, 1)))
    return pix


# ------------------------------------------------------------------- the sets


def signatures():
    """Every combination of four edge colors, in the order the game
    lays a set out: north, east, south, west, low bit first."""
    for value in range(16):
        yield value & 1, (value >> 1) & 1, (value >> 2) & 1, (value >> 3) & 1


def tile_paths(biome):
    for n, e, s, w in signatures():
        for v in range(biome["variants"]):
            yield f"{biome['prefix']}_{n}{e}{s}{w}_{v}.png"


def seed_set(name, biome, colors, seed=None):
    style = style_of(name)
    seed = style["seed"] if seed is None else seed

    base = colors[biome["fill"]]
    rock = colors[style["rock"]]
    ore = colors[style["ore"]]

    # One profile per side and color, shared by every tile of the set.
    shape, paint = {}, {}
    for i, side in enumerate("NESW"):
        for color in (0, 1):
            band = band_profile(color, random.Random(seed + i * 71 + color * 13))
            shape[(side, color)] = band
            paint[(side, color)] = band_materials(band, base, rock)

    air = 0
    for sig in signatures():
        value = sig[0] | sig[1] << 1 | sig[2] << 2 | sig[3] << 3
        for v in range(biome["variants"]):
            rng = random.Random(seed * 31 + value * 977 + v * 104729)

            grid = carve_interior(sig, rng)
            stamp(grid, sig, shape, SOLID)
            pix = to_materials(grid, base, rock, ore, style["ore_rate"], rng)
            stamp(pix, sig, paint, base)

            air += sum(1 for row in pix for c in row if c == AIR)
            write_png(f"{biome['prefix']}_{sig[0]}{sig[1]}{sig[2]}{sig[3]}_{v}.png", pix)

    tiles = 16 * biome["variants"]
    print(f"{name}: {tiles} tiles at {biome['prefix']}_*.png, {100 * air / (tiles * TILE * TILE):.1f}% air")


def check_set(name, biome):
    """Hold the files on disk to the rule the editor gates a save on."""
    tiles = {}
    for sig in signatures():
        for v in range(biome["variants"]):
            path = f"{biome['prefix']}_{sig[0]}{sig[1]}{sig[2]}{sig[3]}_{v}.png"
            if not os.path.exists(path):
                print(f"{name}: {path} is missing")
                return False
            tiles[(sig, v)] = read_png(path)

    faults = 0
    for y in range(TILE):
        for x in range(TILE):
            band = band_of(x, y)
            if band is None:
                continue

            # The first tile of a color speaks for the rest of it.
            leader = {}
            for (sig, v), pix in tiles.items():
                color = 0 if band == "C" else {"N": sig[0], "E": sig[1], "S": sig[2], "W": sig[3]}[band]
                if color not in leader:
                    leader[color] = ((sig, v), pix[y][x])
                    continue
                if pix[y][x] != leader[color][1]:
                    print(
                        f"{name}: tile {sig} variant {v} and tile {leader[color][0][0]} "
                        f"variant {leader[color][0][1]} disagree at cell ({x},{y}), "
                        f"which is in the {band} band"
                    )
                    faults += 1
                    if faults >= 5:
                        return False

    air = sum(1 for pix in tiles.values() for row in pix for c in row if c == AIR)
    percent = 100 * air / (len(tiles) * TILE * TILE)
    if faults == 0:
        print(f"{name}: {len(tiles)} tiles, seams agree, {percent:.1f}% air")
    return faults == 0


def main():
    parser = argparse.ArgumentParser(
        description="Seed or check the Wang tile set of a biome.",
        epilog="Tiles are authored data. Seeding overwrites them, so it needs --force.",
    )
    parser.add_argument("biome", nargs="*", help="biome names, as spelled in data/biomes.txt")
    parser.add_argument("--all", action="store_true", help="every biome that draws a set")
    parser.add_argument("--list", action="store_true", help="list those biomes and stop")
    parser.add_argument("--check", action="store_true", help="verify the files on disk instead of writing")
    parser.add_argument("--force", action="store_true", help="overwrite tiles that already exist")
    parser.add_argument("--seed", type=int, default=None, help="draw another set with the same rules")
    options = parser.parse_args()

    if not os.path.exists(BIOMES_PATH):
        sys.exit(f"cannot read {BIOMES_PATH}; run this from the repository root")

    colors = read_materials()
    biomes = read_biomes()

    if options.list:
        for name, biome in biomes.items():
            style = style_of(name)
            print(
                f"{name}: {16 * biome['variants']} tiles at {biome['prefix']}_*.png, "
                f"{biome['fill']} with {style['rock']} and {style['ore']}"
            )
        return 0

    chosen = list(biomes) if (options.all or options.check) and not options.biome else options.biome
    if not chosen:
        sys.exit("name a biome, or --all. --list shows which ones draw a set.")

    for name in chosen:
        if name not in biomes:
            sys.exit(f"{name} does not draw a tile set. --list shows which biomes do.")

    if options.check:
        return 0 if all(check_set(name, biomes[name]) for name in chosen) else 1

    for name in chosen:
        existing = [p for p in tile_paths(biomes[name]) if os.path.exists(p)]
        if existing and not options.force:
            sys.exit(
                f"{name} already has {len(existing)} tiles, and they are authored data.\n"
                f"Pass --force to draw over them, or edit them in the tile editor."
            )

    for name in chosen:
        seed_set(name, biomes[name], colors, options.seed)

    print("\nLook at what you drew:  ./bin/shot biome=" + chosen[0] + " grid=1 out=shots/look.png")
    return 0


if __name__ == "__main__":
    sys.exit(main())
