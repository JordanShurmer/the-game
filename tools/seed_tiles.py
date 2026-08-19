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

A tile is noise, cut at the level that leaves about half of it open,
and smoothed until the edges are organic. What comes out is broad
winding ground between large lobed masses, with the open and the solid
both connected.

This used to carve caves out of a solid block, on the argument that a
cave system is space inside a mass. A capture of the Noita coal pits at
one pixel per world cell says otherwise: 51% of it is open, the mean
unbroken run of open cells is 30 across and 21 down, and neither phase
is islands in the other. Carving cannot reach that. It leaves rooms
joined by passages, which reads as a building.

The grain is set here rather than left to a smoothing rule to settle
on, because a rule run over even noise agrees with those run lengths
and still comes out as speckle: a mean run says how long the open cells
are and not how they are gathered. GRAIN_X and GRAIN_Y are the size of
a mass, and GRAIN_X being the larger is what lays the masses down.

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
import math
import os
import random
import struct
import sys
import zlib

TILE = 256
SEAM = 4

SOLID, OPEN = 1, 0

AIR = (0, 0, 0, 0)

# The passage that crosses an open edge, and the sizes the carve works
# at. Widen these to open a biome up; the world reads as scratches in
# ground below about a third air and as a hall with pillars above two
# thirds. src/tile_png.odin holds a test at the same numbers.
#
# One cell is one world cell, so these are the sizes a body meets. The
# wizard is 13 cells tall (docs/player.md). The mouth is 41 cells wide
# and the band lip eats up to 6 of it from each side, which leaves a
# channel near 29: over two of him, which is room to walk and jump
# through a border without the border being a hall.
MOUTH_LO, MOUTH_HI = 108, 148
MOUTH_DEPTH = 32
TRUNK_R = (12, 16)

# The cave texture, measured off the reference rather than chosen.
#
# A capture of the Noita coal pits at one pixel per world cell is 51%
# open, and the mean unbroken run of open cells is 30 along x and 21
# along y. That is not a hall with passages off it. It is broad
# winding ground between large lobed masses, with both the open and
# the solid connected, which is what noise gives and what carving out
# of a solid block does not.
#
# The grain is the size of a mass, and it has to be set directly. A
# smoothing rule run over even noise agrees with those two run lengths
# and still comes out as speckle, because a mean run says how long the
# open cells are and not how they are gathered. So the noise is drawn
# on a coarse grid and smoothed up from there, and the grid spacing is
# the feature size: wider than it is tall, which is where the 30
# against 21 comes from.
GRAIN_X = 22          # cells across one lobe of the noise
GRAIN_Y = 15          # and down, so the masses lie down
GRAIN_DETAIL = 0.32   # a second octave at half the spacing, this strong
INTERIOR_OPEN = 0.45  # of the middle of a tile
BAND_OPEN = 0.50      # of a band a passage crosses, the channel aside
BAND_CLOSED_OPEN = 0.50  # of a band with no promised way through, the same
                         # as the rest, or the border shows as a change of density
SMOOTH_PASSES = 2     # of a plain 3x3 majority, to make the edges organic
BLEND = 40            # cells a band fades into the middle of its tile

# A component smaller than this is a pocket, which a cave may have. A
# component larger is a room, and a room nothing reaches is a room
# nobody sees.
POCKET = 1500

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


def smooth_once(grid):
    """One pass of a 3x3 majority, which makes an edge organic.

    The shape of the caves is already decided by the grain of the
    noise. This only settles the edge: it rounds off single cells and
    leaves a wall that wanders by a cell or two, which is the detail a
    256 cell tile is drawn at.
    """
    out = [row[:] for row in grid]
    for y in range(1, TILE - 1):
        up, here, down = grid[y - 1], grid[y], grid[y + 1]
        there = out[y]
        for x in range(1, TILE - 1):
            n = (up[x - 1] + up[x] + up[x + 1]
                 + here[x - 1] + here[x + 1]
                 + down[x - 1] + down[x] + down[x + 1])
            there[x] = SOLID if n >= 5 else OPEN
    return out


def value_noise(rng, grain_x, grain_y):
    """Smooth noise on a grid of the given spacing.

    Random values on a coarse lattice, read back with a smoothstep
    between them. One lobe of the result is one cell of that lattice,
    which is the whole reason for drawing it this way: the size of a
    rock mass is a number here rather than something a smoothing rule
    happens to settle on.
    """
    gx, gy = TILE // grain_x + 2, TILE // grain_y + 2
    lattice = [[rng.random() for _ in range(gx)] for _ in range(gy)]

    def ease(t):
        return t * t * (3 - 2 * t)

    # The x weights repeat for every row, so they are worked out once.
    xs = []
    for x in range(TILE):
        fx = x / grain_x
        x0 = int(fx)
        xs.append((x0, ease(fx - x0)))

    field = []
    for y in range(TILE):
        fy = y / grain_y
        y0 = int(fy)
        ty = ease(fy - y0)
        low, high = lattice[y0], lattice[y0 + 1]
        row = [0.0] * TILE
        for x, (x0, tx) in enumerate(xs):
            a = low[x0] + (low[x0 + 1] - low[x0]) * tx
            b = high[x0] + (high[x0 + 1] - high[x0]) * tx
            row[x] = a + (b - a) * ty
        field.append(row)
    return field


def noise_field(rng, grain_x=None, grain_y=None):
    """The two octaves, summed, as floats.

    The first says how big a mass is and the second gives it lobes and
    inlets. It stays a float field because the bands and the middle of
    a tile have to be mixed before either is cut, not after.
    """
    grain_x = grain_x or GRAIN_X
    grain_y = grain_y or GRAIN_Y
    coarse = value_noise(rng, grain_x, grain_y)
    fine = value_noise(rng, max(2, grain_x // 2), max(2, grain_y // 2))
    for y in range(TILE):
        cr, fr = coarse[y], fine[y]
        for x in range(TILE):
            cr[x] += fr[x] * GRAIN_DETAIL
    return coarse


def field_cut(field, open_fraction):
    """The level that leaves the asked fraction of a field open.

    One cut serves a whole set. A cut worked out per tile would put a
    different level on the same band in two tiles and the seam rule
    would break, so it is measured once and used everywhere.
    """
    flat = sorted(v for row in field for v in row)
    return flat[min(len(flat) - 1, int(open_fraction * len(flat)))]


def field_grid(field, cut):
    """Cut a field into ground and rock, then settle the edge."""
    grid = [[OPEN if v <= cut else SOLID for v in row] for row in field]
    for _ in range(SMOOTH_PASSES):
        grid = smooth_once(grid)
    return grid


# Where in a field the strip that straddles a border is taken from.
STRIP = TILE // 2 - SEAM


def band_value(fields, side, color, x, y):
    """The field value a band cell, or a cell near one, reads.

    One field per axis and color, not one per side and color. The east
    band of a tile and the west band of the tile beside it are two
    strips that touch in the world, and drawing them from two fields
    puts a straight line down every border no matter how well each one
    is made. So one field is cut in half across the border: the left
    half is the east band of the tile on the left and the right half is
    the west band of the tile on the right, and the two join because
    they were never apart.

    Reading past the band is what the crossfade needs, and the strip
    sits in the middle of its field so there is room either way.
    """
    if side == "W":
        return fields[("V", color)][y][STRIP + SEAM + x]
    if side == "E":
        return fields[("V", color)][y][STRIP + x - TILE + SEAM]
    if side == "N":
        return fields[("H", color)][STRIP + SEAM + y][x]
    return fields[("H", color)][STRIP + y - TILE + SEAM][x]


def blend(middle, fields, corner, sig):
    """Mix the middle of a tile into the bands around it.

    A band belongs to its edge color, so it is the same field in every
    tile that carries that color, while the middle is the tile's own.
    Butt the two together and every tile has a ring of cut-off shapes
    SEAM cells in from its border.

    So the fields are crossfaded before either is cut. Inside a band
    the edge field stands alone, which is what keeps the band shared.
    Over the next BLEND cells the tile's own field takes over. What
    comes out has no ring in it, because there is no longer a place
    where one field stops and another starts.
    """
    colors = dict(zip("NESW", sig))
    out = [row[:] for row in middle]
    for y in range(TILE):
        row = out[y]
        for x in range(TILE):
            reach = (
                ("W", x - SEAM),
                ("E", (TILE - 1 - x) - SEAM),
                ("N", y - SEAM),
                ("S", (TILE - 1 - y) - SEAM),
            )
            inside = [side for side, d in reach if d < 0]
            if len(inside) >= 2:
                row[x] = corner[y][x]
                continue
            if inside:
                side = inside[0]
                row[x] = band_value(fields, side, colors[side], x, y)
                continue
            side, d = min(reach, key=lambda p: p[1])
            if d >= BLEND:
                continue
            w = 1.0 - d / BLEND
            row[x] = middle[y][x] * (1.0 - w) + band_value(fields, side, colors[side], x, y) * w
    return out


def components(grid):
    """Label every run of connected open cells, and say how big it is."""
    label = [[-1] * TILE for _ in range(TILE)]
    sizes = []
    for sy in range(TILE):
        for sx in range(TILE):
            if grid[sy][sx] != OPEN or label[sy][sx] >= 0:
                continue
            index = len(sizes)
            label[sy][sx] = index
            stack = [(sx, sy)]
            size = 0
            while stack:
                x, y = stack.pop()
                size += 1
                for nx, ny in ((x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)):
                    if 0 <= nx < TILE and 0 <= ny < TILE:
                        if grid[ny][nx] == OPEN and label[ny][nx] < 0:
                            label[ny][nx] = index
                            stack.append((nx, ny))
            sizes.append(size)
    return label, sizes


def nearest_of(label, want, x0, y0):
    """The cell of one component closest to a place. None if it has none."""
    best, best_d = None, None
    for y in range(TILE):
        row = label[y]
        dy = y - y0
        for x in range(TILE):
            if row[x] != want:
                continue
            d = (x - x0) ** 2 + dy * dy
            if best_d is None or d < best_d:
                best, best_d = (x, y), d
    return best


def connect(grid, sig, rng):
    """Join every mouth, and every room, to one network.

    Noise says nothing about whether a tile can be walked across. A
    mouth that opens onto rock is a border the world cannot pass, and
    the lattice would come out as a field of sealed squares. So the
    largest network is the one the tile keeps, every open side is dug
    through to it, and any room too big to be a pocket is joined to it
    as well.
    """
    label, sizes = components(grid)
    if not sizes:
        return grid
    main = max(range(len(sizes)), key=lambda i: sizes[i])

    mid = (MOUTH_LO + MOUTH_HI) // 2
    inner = SEAM + MOUTH_DEPTH // 2
    mouths = {
        "N": (mid, inner),
        "S": (mid, TILE - 1 - inner),
        "W": (inner, mid),
        "E": (TILE - 1 - inner, mid),
    }

    targets = []
    for side, color in zip("NESW", sig):
        if color == 1:
            targets.append(mouths[side])
    for index, size in enumerate(sizes):
        if index != main and size >= POCKET:
            targets.append(nearest_of(label, index, TILE // 2, TILE // 2))

    for point in targets:
        if point is None:
            continue
        x0, y0 = point
        if label[y0][x0] == main:
            continue
        goal = nearest_of(label, main, x0, y0)
        if goal is None:
            continue
        carve_disc(grid, x0, y0, rng.randint(*TRUNK_R))
        carve_walk(grid, x0, y0, goal[0], goal[1], rng.randint(*TRUNK_R), rng, wobble=0.7)
    return grid


def carve_walk(grid, x0, y0, x1, y1, r, rng, wobble=0.55):
    """A passage from one place to another, cut the way water cuts one.

    It leans toward where it is going and is pushed sideways at every
    step, and its width drifts, so it comes out with throats and
    galleries in it rather than one straight bore.
    """
    x, y = float(x0), float(y0)
    radius = float(r)

    for _ in range(1200):
        dx, dy = x1 - x, y1 - y
        distance = max(1e-6, (dx * dx + dy * dy) ** 0.5)
        if distance <= 3.0:
            break
        dx, dy = dx / distance, dy / distance

        swing = rng.uniform(-wobble, wobble)
        x += dx - dy * swing
        y += dy + dx * swing
        radius = min(r + 8, max(12.0, radius + rng.uniform(-0.35, 0.35)))
        carve_disc(grid, round(x), round(y), int(radius))

    carve_disc(grid, x1, y1, int(radius))


def carve_interior(sig, rng, sides, corner, cut):
    """The inside of a tile: ground and rock, from noise.

    The first version of this cut caves out of a solid block, on the
    argument that a cave system is space inside a mass. A capture of
    the reference biome says otherwise. There the open and the solid
    are both connected and about the same amount of the picture, which
    is what noise gives and what carving does not reach: carving leaves
    rooms joined by passages, and the reference has broad ground
    between masses.

    So the tile is noise, crossfaded into the bands around it, cut at
    the level the whole set is cut at. The only thing drawn by hand
    afterward is whatever it takes to make every mouth reach the same
    network.
    """
    grid = field_grid(blend(noise_field(rng), sides, corner, sig), cut)

    # The mouths have to be open before the network is measured, or a
    # mouth that landed on rock would be dug out to a network it is
    # already part of.
    for side, color in zip("NESW", sig):
        if color == 0:
            continue
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

    return connect(grid, sig, rng)


# ------------------------------------------------------------------ the bands


def band_profile(side, color, fields, cut, rng):
    """One border band, as a [SEAM][TILE] grid of SOLID and OPEN.

    It depends on the side and the color only, so every tile that
    carries that color holds the same band.

    It is cut from the same field the middle of a tile is crossfaded
    into, at the same level, so a band is not a strip of something else
    laid over the cave: it is the cave, at the place the lattice needs
    every tile to agree.

    A color 1 band also carries a channel wide enough to walk through,
    forced through every row, so the way from one tile to the next is a
    promise and not something the noise happened to leave.
    """
    band = [[SOLID] * TILE for _ in range(SEAM)]
    for depth in range(SEAM):
        row = band[depth]
        for along in range(TILE):
            # depth runs into the tile and along runs down the border,
            # and which of those is x in the world is what the side says.
            if side == "W":
                x, y = depth, along
            elif side == "E":
                x, y = TILE - 1 - depth, along
            elif side == "N":
                x, y = along, depth
            else:
                x, y = along, TILE - 1 - depth
            row[along] = OPEN if band_value(fields, side, color, x, y) <= cut else SOLID

    # The cut leaves single cells that the middle of a tile does not
    # have, because the middle is smoothed and a band cannot be: a pass
    # over a band would reach the cells beyond it, which belong to a
    # different tile in every place the band is used.
    for _ in range(SMOOTH_PASSES):
        band = smooth_band(band)

    if color == 0:
        return band

    # The channel: the lip wanders as the band goes deeper instead of
    # being drawn again on every row. SEAM rows of independent jitter is
    # a comb of SEAM teeth standing in the mouth of every border.
    lo, hi = MOUTH_LO + 4, MOUTH_HI - 4
    for depth in range(SEAM):
        lo = min(MOUTH_LO + 8, max(MOUTH_LO, lo + rng.randint(-2, 2)))
        hi = max(MOUTH_HI - 8, min(MOUTH_HI, hi + rng.randint(-2, 2)))
        for along in range(lo, hi + 1):
            band[depth][along] = OPEN
    return band


def smooth_band(band):
    """The 3x3 majority, along a band only.

    A band is SEAM deep, and the rows beyond it belong to whichever
    tile is using the band, so they cannot be looked at. The pass runs
    along the band and treats what is past the ends of the depth axis
    as more of the same, which keeps the rule the same shape without
    reading anything it must not.
    """
    out = [row[:] for row in band]
    for depth in range(SEAM):
        up = band[max(0, depth - 1)]
        here = band[depth]
        down = band[min(SEAM - 1, depth + 1)]
        for along in range(1, TILE - 1):
            n = (up[along - 1] + up[along] + up[along + 1]
                 + here[along - 1] + here[along + 1]
                 + down[along - 1] + down[along] + down[along + 1])
            out[depth][along] = SOLID if n >= 5 else OPEN
    return out


def band_materials(band, base, rock, wall=3):
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

    `corner` is a whole grid rather than one value. A corner cell is in
    two bands at once and so belongs to the whole set, which used to
    make it a solid square; four solid squares on every tile is the
    lattice drawn in the one place the bands cannot vary. A patch of
    cave shared by the set is just as common to all of them and shows
    nothing.
    """
    n, e, s_, w = sig
    for depth in range(SEAM):
        for along in range(TILE):
            target[along][depth] = profiles[("W", w)][depth][along]
            target[along][TILE - 1 - depth] = profiles[("E", e)][depth][along]
            target[depth][along] = profiles[("N", n)][depth][along]
            target[TILE - 1 - depth][along] = profiles[("S", s_)][depth][along]
    for y in range(TILE):
        for x in range(TILE):
            if band_of(x, y) == "C":
                target[y][x] = corner[y][x]


# --------------------------------------------------------------- the material


def to_materials(grid, base, rock, ore, ore_rate, rng, wall=3):
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
    for _ in range(int(ore_rate * 56)):
        x, y = rng.randrange(SEAM, TILE - SEAM), rng.randrange(SEAM, TILE - SEAM)
        for _ in range(rng.randint(12, 36)):
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

    # One cut for the whole set, so the same band comes out the same in
    # every tile that carries it.
    cut = field_cut(noise_field(random.Random(seed + 4242)), INTERIOR_OPEN)

    # One field per edge axis and color: a vertical border is one field
    # cut in half, and so is a horizontal one. Plus the corners, which
    # belong to every tile of the set at once.
    fields = {}
    for i, axis in enumerate("VH"):
        for color in (0, 1):
            fields[(axis, color)] = noise_field(random.Random(seed + i * 71 + color * 13))
    corner_field = noise_field(random.Random(seed + 8191))

    shape, paint = {}, {}
    for side in "NESW":
        for color in (0, 1):
            band = band_profile(side, color, fields, cut,
                                random.Random(seed + ord(side) * 31 + color * 13))
            shape[(side, color)] = band
            paint[(side, color)] = band_materials(band, base, rock)

    corner_rng = random.Random(seed + 8191)
    corner_shape = field_grid(corner_field, cut)
    corner_paint = to_materials(corner_shape, base, rock, ore, style["ore_rate"], corner_rng)

    air = 0
    for sig in signatures():
        value = sig[0] | sig[1] << 1 | sig[2] << 2 | sig[3] << 3
        for v in range(biome["variants"]):
            rng = random.Random(seed * 31 + value * 977 + v * 104729)

            grid = carve_interior(sig, rng, fields, corner_field, cut)
            stamp(grid, sig, shape, corner_shape)
            pix = to_materials(grid, base, rock, ore, style["ore_rate"], rng)
            stamp(pix, sig, paint, corner_paint)

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
