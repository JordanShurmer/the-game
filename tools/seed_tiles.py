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
one pixel per world cell says otherwise: 51% of it is open, and neither
phase is islands in the other. Carving cannot reach that. It leaves
rooms joined by passages, which reads as a building.

The grain is set here rather than left to a smoothing rule to settle
on, because a rule run over even noise comes out as speckle: a mean run
says how long the open cells are and not how they are gathered. GRAIN_X
and GRAIN_Y are the size of a mass, and GRAIN_X being the larger is
what lays the masses down.

The noise is gradient noise, not value noise. That is the difference
between a cave and a corridor, and it is the whole of why the world
used to read as blocky. Value noise interpolates a number held at each
point of a lattice, so every contour it draws leans on the lattice
axes: cut one in half and the masses come out as rectangles with square
corners and long level roofs, however fine the lattice is. Gradient
noise holds a direction at each lattice point instead and reads the
distance along it, so the contours cross the lattice at any angle and
the walls come out rounded and diagonal. Nothing downstream changed to
get that; only the field did.

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

WHAT THE RULE COSTS, AND THE RUNG THAT WOULD PAY IT

A forced channel sits at the middle of the side it crosses, and it has
to sit at the same place in every band of that color, because that is
what makes the band shared. The band above a tile and the band below
the tile over it are two halves of one strip, so the two channels line
up, and a run of tiles that all carry color 1 above and below leaves a
shaft straight through them. Half the horizontal edges carry color 1,
so a shaft is about two tiles long, and it is visible at
`./bin/shot step=4` and nowhere a player stands. A mine with shafts in
it is not wrong. The rung that would break them up is WANG_COLORS 4,
which gives each axis more than one place to put a mouth and costs a
set of 256 tiles instead of 16.

ADDING A BIOME

Give it `generator = wang` and a `tiles` prefix in data/biomes.txt, add
a line to STYLES below if the default palette is wrong for it, then run
this. The set starts as flat fill until something draws it, so a biome
with no entry here still works; it just looks like nothing.

THREE TILES ARE A BUILT ROOM, NOT NOISE

`ROOMS` below names three of the Coalmine set's 32 tiles, one for each
count of open sides that a room can make sense of, and only their
second variant, so the first is still plain cave and a player meets
the room sometimes and not always. Each is a **shell set into the
cave**, not a hole cut in a solid block: `seed_set` runs
`carve_interior` for these tiles exactly as it does for a plain one,
so the noise cave is already there, and a room only replaces the
footprint of its own shell. Everywhere the shell is not, the cave the
tile would have drawn anyway is what is left.

The shell (`build_shell`) is three courses, from the room out: its
open interior; a wall `WALL_T` (6) cells thick, in the room's own
material; a course of Rock `PACK_T` (4) cells thick, packed between
that wall and the cave. The silhouette (`in_shell_shape`) is never a
rectangle -- a semi-elliptical cap at the top, at the bottom, or both,
with no radius under 24 cells, draws either a **vault** (a wide dome
over a flat floor) or a **capsule** (round at both ends). The
packing's outer face wanders a cell or two, by a few summed sine
waves at random phase (`wobble_field`); the wall's own two faces stay
true, because a built thing is straight and the rock it was fitted
into was not.

  - coalmine_1111_1, the Cistern: a Steel capsule, all four edges
    open. Doorways are cut through the shell on all four sides, each
    framed in Steel, and a tunnel is walked from every mouth to the
    doorway it faces (`carve_mouth_tunnel`), so each still arrives
    through cave, not a bore drilled straight through rock. The tank's
    own rounded bottom, already Steel-lined by the wall, is the basin:
    it only wants filling with Water to a flat level. Two Wood planks
    on posts cross above it, staggered, with a gap over the middle so
    the north doorway drops a player toward the water. A Gold vein
    crawls the ceiling rock from where it meets the wall's outer face,
    and a down-pointing triangle -- water's mark -- is etched into the
    wall above the basin.
  - coalmine_0101_1, the Magazine: a Rock vault, coursed in Gravel
    joints, east and west open. A beamed Wood ceiling rides four
    pillars, each with a base and a capital; Coal heaps sit against
    two of them, a Steel trough of Oil fills one bay and a Tnt cache,
    walled off in Wood, fills another. A circle-with-a-dot is etched
    into the east wall.
  - coalmine_1010_1, the Well: a Rock capsule banded in Steel, north
    and south open, tall enough to be a shaft rather than a room lying
    on its side. Wood scaffold ledges on brackets driven into the
    wall alternate down it. At the bottom a clear Rock ledge stands on
    one side of the floor; a Steel-rimmed pit of Lava with an
    Obsidian lip -- a rim course around the whole top edge of the pit,
    not a bar across it -- sits on the other, so the hazard is beside
    the way down and never blind under it. An up-pointing triangle --
    fire's mark -- is etched into the west wall.

A room draws its own material overlay on top of the grid it shapes,
so a feature can be any material rather than only rock and air.
`seed_set` runs the room after `carve_interior`, then stamps the
shared bands over both exactly as it does for a cave tile. The
overlay goes on last, and only where `band_of` is None: a room may not
write a single cell of a band, because every tile that carries that
band's colour shares it, and a feature only one of them agreed to
would show as a seam. `room_carve` sets the grid freely, bands
included, because `stamp` overwrites every band cell after a room
runs regardless of what the room left there.

The one thing a room must never do is stand something solid across a
mouth's own tunnel. A doorway (`cut_doorway`) is cut clear through the
shell before anything else is built, framed in the room's own
material, and every feature after it -- pillar, cache, cask, pit -- is
kept to the bays between doorways, never across one.
"""

import argparse
import math
import os
import random
import struct
import sys
import zlib

TILE = 512
SEAM = 4

SOLID, OPEN = 1, 0

AIR = (0, 0, 0, 0)

# The passage that crosses an open edge, and the sizes the carve works
# at. Widen these to open a biome up; the world reads as scratches in
# ground below about a third air and as a hall with pillars above two
# thirds. src/tile_png.odin holds a test at the same numbers.
#
# One cell is one world cell, so these are the sizes a body meets. The
# wizard is 13 cells tall (docs/player.md). The mouth is 82 cells wide
# and the band lip eats up to 8 of it from each side, which leaves a
# channel of at least 66, five of him. The noise either side of the
# forced channel opens more of the band than that, so the narrowest
# measured over the shipped set is 77, and a border is a way through he
# walks into rather than a gap he has to line himself up with.
MOUTH_LO, MOUTH_HI = 215, 296
MOUTH_DEPTH = 64
TRUNK_R = (24, 32)

# The cave texture: the shape off the reference, the size off the
# wizard.
#
# A capture of the Noita coal pits at one pixel per world cell is 51%
# open, and neither phase is islands in the other. That is not a hall
# with passages off it. It is broad winding ground between large lobed
# masses, which is what noise gives and what carving out of a solid
# block does not.
#
# The same capture measures a mean unbroken run of open cells of 30
# along x and 21 along y, and this set was drawn to those two numbers
# once. Against a body 13 cells tall that is a cave a little under two
# of him, and played it reads as a tunnel he only just clears. So the
# shape is still the reference's and the size is no longer: the grain
# is set to leave a mean run near 72 across and 52 down, five of him
# and four of him.
#
# The grain is the size of a mass, and it has to be set directly. A
# smoothing rule run over even noise agrees with any run length you
# like and still comes out as speckle, because a mean run says how long
# the open cells are and not how they are gathered. So the noise is
# drawn on a coarse lattice and read back between its points, and the
# lattice spacing is the feature size: wider than it is tall, so the
# masses lie down.
#
# A gradient lattice is not a value lattice: one point of it holds a
# direction and its reach carries about half as far again, where a
# value lattice holds a number and reaches one spacing. So these
# numbers are larger than the run lengths they leave, and larger again
# than the value noise numbers this file used to carry.
GRAIN_X = 76          # cells across one lobe of the noise
GRAIN_Y = 52          # and down, so the masses lie down
GRAIN_DETAIL = 0.20   # a second octave at half the spacing, this strong
INTERIOR_OPEN = 0.45  # of the middle of a tile
BAND_OPEN = 0.50      # of a band a passage crosses, the channel aside
BAND_CLOSED_OPEN = 0.50  # of a band with no promised way through, the same
                         # as the rest, or the border shows as a change of density
SMOOTH_PASSES = 2     # of a plain 3x3 majority, to make the edges organic
BLEND = 80            # cells a band fades into the middle of its tile
ORE_SEEDS = 85        # veins started per 100k cells of tile, before ore_rate

# Cells of rock face between the open cave and the fill behind it.
#
# This one does not follow the grain, and must not. It is the face of
# the mass, drawn a cell at a time, the same argument that keeps
# SMOOTH_PASSES and PLAYER_CLIMB where they are: a bigger cave gets a
# finer wall, not a thicker crust. It is also bounded by SEAM, because
# band_materials draws the band's face from the band alone and can
# reach no deeper than the band is; a rim wider than that would come
# out one material in a band and another one cell past it, which is
# the lattice made visible.
WALL = 3

# A component smaller than this is a pocket, which a cave may have. A
# component larger is a room, and a room nothing reaches is a room
# nobody sees. It is an area, so it follows the square of the grain.
POCKET = 6000

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


def gradient_noise(rng, grain_x, grain_y):
    """Smooth noise on a lattice of the given spacing.

    A direction at every point of a coarse lattice, read back as the
    distance along it, blended with a smoothstep. One lobe of the
    result is about one cell of that lattice, which is the whole reason
    for drawing it this way: the size of a rock mass is a number here
    rather than something a smoothing rule happens to settle on.

    A direction, not a number. That is the one line that decides
    whether the caves come out blocky. Hold a number at each lattice
    point and every cell between four of them reads a blend of four
    numbers, which is largest at a corner and level along a row: the
    contour that a cut then draws runs along the lattice, and a world
    of rectangles with square corners comes out of it, at any spacing.
    Hold a direction and a cell reads how far it lies along four
    directions that point anywhere, so the field has no axis of its own
    and neither do the caves.

    The field is centred on 0.5 so it can be mixed with any other field
    this file draws. The spread is nothing to do with the cut, which is
    a quantile of the field it is measured on.
    """
    gx, gy = TILE // grain_x + 2, TILE // grain_y + 2
    lattice = [
        [(math.cos(a), math.sin(a)) for a in (rng.uniform(0, 2 * math.pi) for _ in range(gx))]
        for _ in range(gy)
    ]

    def ease(t):
        return t * t * (3 - 2 * t)

    # The x terms repeat for every row, so they are worked out once.
    xs = []
    for x in range(TILE):
        fx = x / grain_x
        x0 = int(fx)
        xs.append((x0, fx - x0, ease(fx - x0)))

    field = []
    for y in range(TILE):
        fy = y / grain_y
        y0 = int(fy)
        dy = fy - y0
        wy = ease(dy)
        low, high = lattice[y0], lattice[y0 + 1]
        row = [0.0] * TILE
        for x, (x0, dx, wx) in enumerate(xs):
            a0, a1 = low[x0], low[x0 + 1]
            b0, b1 = high[x0], high[x0 + 1]
            top = (a0[0] * dx + a0[1] * dy)
            top += ((a1[0] * (dx - 1) + a1[1] * dy) - top) * wx
            bottom = (b0[0] * dx + b0[1] * (dy - 1))
            bottom += ((b1[0] * (dx - 1) + b1[1] * (dy - 1)) - bottom) * wx
            row[x] = 0.5 + 0.7 * (top + (bottom - top) * wy)
        field.append(row)
    return field


def noise_field(rng, grain_x=None, grain_y=None):
    """The two octaves of gradient noise, summed, as floats.

    The first says how big a mass is and the second gives it lobes and
    inlets. It stays a float field because the bands and the middle of
    a tile have to be mixed before either is cut, not after.
    """
    grain_x = grain_x or GRAIN_X
    grain_y = grain_y or GRAIN_Y
    coarse = gradient_noise(rng, grain_x, grain_y)
    fine = gradient_noise(rng, max(2, grain_x // 2), max(2, grain_y // 2))
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

    # Steps, not distance: a walk crosses at most a tile, and one step
    # covers about a cell, so this only has to be past TILE.
    for _ in range(4 * TILE):
        dx, dy = x1 - x, y1 - y
        distance = max(1e-6, (dx * dx + dy * dy) ** 0.5)
        if distance <= 3.0:
            break
        dx, dy = dx / distance, dy / distance

        swing = rng.uniform(-wobble, wobble)
        x += dx - dy * swing
        y += dy + dx * swing
        radius = min(r + 16, max(24.0, radius + rng.uniform(-0.35, 0.35)))
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


def band_materials(band, base, rock, wall=WALL):
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


def to_materials(grid, base, rock, ore, ore_rate, rng, wall=WALL):
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
    #
    # Counted per area rather than per tile. A tile that grew and kept
    # its count would hold the same handful of veins spread over four
    # times the rock, and a mine with no metal in it is what comes out.
    # The vein is as long as the rock is thick, so its length follows
    # the grain the way every other size in this file does.
    for _ in range(int(ore_rate * ORE_SEEDS * TILE * TILE / 100_000)):
        x, y = rng.randrange(SEAM, TILE - SEAM), rng.randrange(SEAM, TILE - SEAM)
        for _ in range(rng.randint(GRAIN_Y // 2, GRAIN_Y + GRAIN_X // 2)):
            if band_of(x, y) is None and pix[y][x] == rock:
                pix[y][x] = ore
            x = min(TILE - 1, max(0, x + rng.randint(-1, 1)))
            y = min(TILE - 1, max(0, y + rng.randint(-1, 1)))
    return pix


# ------------------------------------------------------------------ the rooms

# A room is a built shell set into the noise cave, not a hole cut in a
# solid block. `seed_set` runs `carve_interior` for a room tile exactly
# as it does for a plain one, so the cave is already there; a room then
# stands its shell in that cave and cuts its own interior inside the
# shell. The cave is what is left everywhere the shell is not.

WALL_T = 6   # the shell's own wall, in the room's material
PACK_T = 4   # the course of Rock packed between that wall and the cave
SHELL_T = WALL_T + PACK_T

ROOM_MOUTH_LO, ROOM_MOUTH_HI = MOUTH_LO - 10, MOUTH_HI + 10


def room_carve(grid, x0, x1, y0, y1, value):
    """Set a rectangle of the open/solid grid."""
    for y in range(max(0, y0), min(TILE, y1)):
        row = grid[y]
        for x in range(max(0, x0), min(TILE, x1)):
            row[x] = value


def room_paint(overlay, x0, x1, y0, y1, color):
    """Set a rectangle of the material overlay, skipping every band
    cell: the overlay is stamped after the bands are, so a cell it
    wrote there would stick, and a band belongs to the whole set."""
    for y in range(max(0, y0), min(TILE, y1)):
        for x in range(max(0, x0), min(TILE, x1)):
            if band_of(x, y) is None:
                overlay[(x, y)] = color


def room_erase(overlay, x0, x1, y0, y1):
    """Remove overlay entries from a rectangle: used to open a doorway
    back to plain Air through wall or packing already painted there."""
    for y in range(max(0, y0), min(TILE, y1)):
        for x in range(max(0, x0), min(TILE, x1)):
            overlay.pop((x, y), None)


def solid_rect(grid, overlay, colors, material, x0, x1, y0, y1):
    """Recolour a rectangle, but only the cells that are already solid.
    A doorway's frame must thicken the wall that is really there, not
    stand a new block into whatever the cell next to it happens to be
    -- open cave, past the packing's own wandering face, reads as a
    stub in the air rather than part of the wall."""
    for y in range(max(0, y0), min(TILE, y1)):
        for x in range(max(0, x0), min(TILE, x1)):
            if grid[y][x] == SOLID and band_of(x, y) is None:
                overlay[(x, y)] = colors[material]


def fit_rect(grid, overlay, colors, material, inside, x0, x1, y0, y1, value=SOLID):
    """Set a rectangle, but only where `inside` (the room's own bare
    shape test) says yes. Nothing built may cross the shell, so every
    fitting -- beam, post, plank, bin, crate, brace, ladder -- is
    placed with this, never with the unclipped `room_carve`."""
    for y in range(max(0, y0), min(TILE, y1)):
        for x in range(max(0, x0), min(TILE, x1)):
            if inside(x, y):
                grid[y][x] = value
                if band_of(x, y) is None:
                    overlay[(x, y)] = colors[material]


def fit_open(grid, overlay, inside, x0, x1, y0, y1):
    for y in range(max(0, y0), min(TILE, y1)):
        for x in range(max(0, x0), min(TILE, x1)):
            if inside(x, y):
                grid[y][x] = OPEN
                overlay.pop((x, y), None)


def in_shell_shape(x, y, x0, x1, y0, y1, top_rx, top_ry, bot_rx, bot_ry):
    """A rounded room silhouette: straight sides, a semi-elliptical cap
    of half-axes (top_rx, top_ry) at the top and one of (bot_rx, bot_ry)
    at the bottom. top_rx at half the width turns the top cap into a
    dome spanning the whole room -- a vault's ceiling; the same at the
    bottom too makes a capsule, rounded at both ends. A small bot_rx and
    bot_ry (24, the least this file ever draws) leaves a flat floor with
    only its corners rounded off."""
    if y < y0 + top_ry:
        cx = min(max(x, x0 + top_rx), x1 - top_rx)
        nx = (x - cx) / top_rx
        ny = (y - (y0 + top_ry)) / top_ry
        return nx * nx + ny * ny <= 1.0
    if y > y1 - bot_ry:
        cx = min(max(x, x0 + bot_rx), x1 - bot_rx)
        nx = (x - cx) / bot_rx
        ny = (y - (y1 - bot_ry)) / bot_ry
        return nx * nx + ny * ny <= 1.0
    return x0 <= x <= x1


def wobble_field(rng, n=5, scale=2.2):
    """A slow, smooth wander, a cell or two either way, built from a
    few sine waves at random phase and rate. Used only on the outer
    face of a room's rock packing: a built wall's own two faces stay
    true, but the rock it is packed against has been left as it was
    found."""
    phases = [rng.uniform(0, 2 * math.pi) for _ in range(n)]
    freqs = [rng.uniform(2.0, 5.0) for _ in range(n)]

    def f(t):
        return scale * sum(math.sin(t * fr + ph) for fr, ph in zip(freqs, phases)) / n

    return f


def build_shell(grid, overlay, colors, material, rng, x0, x1, y0, y1, top_rx, top_ry, bot_rx, bot_ry):
    """Set a shell into the cave already carved in `grid`: a wall of
    `material` (WALL_T thick), a course of Rock packed outside that
    (PACK_T thick), and the room's own open interior inside the wall.
    Nothing outside the packing is touched, so the cave stands right up
    against it -- the room sits in the cave system, not apart from it.
    Returns a shape test for the bare interior, for a caller to sculpt
    and clip against."""
    wob = wobble_field(rng)
    cx0, cy0 = (x0 + x1) / 2, (y0 + y1) / 2
    margin = int(SHELL_T + max(top_ry, bot_ry) + 12)
    bx0, bx1 = int(x0 - top_rx - margin), int(x1 + top_rx + margin)
    by0, by1 = int(y0 - margin), int(y1 + margin)
    for y in range(max(0, by0), min(TILE, by1)):
        for x in range(max(0, bx0), min(TILE, bx1)):
            if in_shell_shape(x, y, x0, x1, y0, y1, top_rx, top_ry, bot_rx, bot_ry):
                grid[y][x] = OPEN
                continue
            if in_shell_shape(x, y, x0 - WALL_T, x1 + WALL_T, y0 - WALL_T, y1 + WALL_T,
                               top_rx + WALL_T, top_ry + WALL_T, bot_rx + WALL_T, bot_ry + WALL_T):
                grid[y][x] = SOLID
                if band_of(x, y) is None:
                    overlay[(x, y)] = colors[material]
                continue
            t = math.atan2(y - cy0, x - cx0)
            extra = SHELL_T + wob(t)
            if in_shell_shape(x, y, x0 - extra, x1 + extra, y0 - extra, y1 + extra,
                               top_rx + extra, top_ry + extra, bot_rx + extra, bot_ry + extra):
                grid[y][x] = SOLID
                if band_of(x, y) is None:
                    overlay[(x, y)] = colors["Rock"]

    return lambda x, y: in_shell_shape(x, y, x0, x1, y0, y1, top_rx, top_ry, bot_rx, bot_ry)


def cut_doorway(grid, overlay, colors, material, side, near, far, wall_at, span=72, frame=8, collar=None):
    """Cut a doorway through the shell on `side` ('N', 'E', 'S' or 'W'),
    clear from `near` to `far` along the wall's own depth. The frame is
    a collar right where the wall crosses, `collar` cells deep centred
    on `wall_at` -- a thickening in the plane of the wall itself, not a
    bar standing out into the room."""
    if collar is None:
        collar = SHELL_T + 8
    d0, d1 = sorted((near, far))
    c0, c1 = sorted((wall_at - collar // 2, wall_at + collar // 2))
    mid = (MOUTH_LO + MOUTH_HI) // 2
    lo, hi = mid - span // 2, mid + span // 2
    if side in "NS":
        room_carve(grid, lo, hi, d0, d1, OPEN)
        room_erase(overlay, lo, hi, d0, d1)
        for a0, a1 in ((lo - frame, lo), (hi, hi + frame)):
            solid_rect(grid, overlay, colors, material, a0, a1, c0, c1)
    else:
        room_carve(grid, d0, d1, lo, hi, OPEN)
        room_erase(overlay, d0, d1, lo, hi)
        for a0, a1 in ((lo - frame, lo), (hi, hi + frame)):
            solid_rect(grid, overlay, colors, material, c0, c1, a0, a1)


def carve_mouth_tunnel(grid, rng, side, x0, x1, y0, y1, top_rx, top_ry, bot_rx, bot_ry):
    """Walk a tunnel from the mouth this side forces open to the
    doorway that faces it, the way any two rooms of cave are joined --
    `carve_walk` gives it throats and galleries, not one straight bore.
    Whatever `carve_interior` and the shell already opened along the
    way only helps; this is what guarantees the two meet."""
    mid = (MOUTH_LO + MOUTH_HI) // 2
    inner = SEAM + MOUTH_DEPTH // 2
    starts = {
        "N": (mid, inner), "S": (mid, TILE - 1 - inner),
        "W": (inner, mid), "E": (TILE - 1 - inner, mid),
    }
    doors = {
        "N": (mid, y0 - SHELL_T - 8), "S": (mid, y1 + SHELL_T + 8),
        "W": (x0 - SHELL_T - 8, mid), "E": (x1 + SHELL_T + 8, mid),
    }
    sx, sy = starts[side]
    dx, dy = doors[side]
    carve_walk(grid, sx, sy, dx, dy, rng.randint(*TRUNK_R), rng, wobble=0.6)


def place_ribs(grid, overlay, colors, material, x0, x1, y0, y1, top_ry, bot_ry, rng, skip=()):
    """A rib every 70 to 100 cells down each straight side wall: the
    same material, 10 cells further in than the wall's own face, 20
    long, so the wall has a rhythm instead of being one dead line. A
    span in `skip` (a (lo, hi) pair of y) is where a doorway already
    breaks the wall, and gets no rib."""
    lo, hi = y0 + top_ry, y1 - bot_ry
    if hi - lo < 40:
        return
    step = rng.uniform(70, 100)
    y = lo + step / 2
    while y < hi:
        y0r, y1r = int(y - 10), int(y + 10)
        if not any(a <= y0r and y1r <= b for a, b in skip):
            room_carve(grid, x0 + WALL_T, x0 + WALL_T + 10, y0r, y1r, SOLID)
            room_paint(overlay, x0 + WALL_T, x0 + WALL_T + 10, y0r, y1r, colors[material])
            room_carve(grid, x1 - WALL_T - 10, x1 - WALL_T, y0r, y1r, SOLID)
            room_paint(overlay, x1 - WALL_T - 10, x1 - WALL_T, y0r, y1r, colors[material])
        y += step


def course_masonry(overlay, colors, base, joint, x0, x1, y0, y1, block_w=28, block_h=14, jw=3):
    """A running-bond masonry pattern painted over a wall wherever it
    is currently `base`: a joint of `joint` between courses (horizontal
    bands `block_h` tall) and between blocks within a course
    (`block_w` wide), offset by half a block every other course, so
    the joints stagger the way real coursing does."""
    period_h, period_w = block_h + jw, block_w + jw
    for y in range(max(0, y0), min(TILE, y1)):
        course = (y - y0) // period_h
        within = (y - y0) % period_h
        offset = (block_w // 2) if course % 2 else 0
        h_joint = within < jw
        for x in range(max(0, x0), min(TILE, x1)):
            if overlay.get((x, y)) != colors[base]:
                continue
            v_joint = ((x - x0 + offset) % period_w) < jw
            if (h_joint or v_joint) and band_of(x, y) is None:
                overlay[(x, y)] = colors[joint]


def rivet_wall(overlay, colors, base, rivet, hoop, x0, x1, y0, y1, top_rx, top_ry, bot_rx, bot_ry):
    """A steel tank's own texture: a rivet dot every 16 cells around
    the seam, and a Rock hoop 10 cells wide banding the tank every 110
    cells or so around its whole perimeter."""
    cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
    avg_r = ((x1 - x0) / 2 + (y1 - y0) / 2 + top_rx + top_ry + bot_rx + bot_ry) / 5
    circumference = 2 * math.pi * avg_r
    n_hoops = max(2, round(circumference / 110))
    hoop_half_angle = max(0.02, (5 / avg_r))
    margin = int(SHELL_T + max(top_ry, bot_ry) + 8)
    bx0, bx1 = int(x0 - top_rx - margin), int(x1 + top_rx + margin)
    by0, by1 = int(y0 - margin), int(y1 + margin)
    for y in range(max(0, by0), min(TILE, by1)):
        for x in range(max(0, bx0), min(TILE, bx1)):
            if overlay.get((x, y)) != colors[base]:
                continue
            ang = math.atan2(y - cy, x - cx)
            arc = ang * avg_r
            hit_hoop = False
            for k in range(n_hoops):
                target = -math.pi + 2 * math.pi * k / n_hoops
                d = (ang - target + math.pi) % (2 * math.pi) - math.pi
                if abs(d) < hoop_half_angle:
                    hit_hoop = True
                    break
            if band_of(x, y) is None:
                if hit_hoop:
                    overlay[(x, y)] = colors[hoop]
                elif (arc % 16) < 2:
                    overlay[(x, y)] = colors[rivet]


def place_brace(grid, overlay, colors, material, inside, ax, ay, bx, by, width=6):
    """A diagonal strut from (ax, ay) to (bx, by): what says a frame is
    braced rather than just resting together."""
    dx, dy = bx - ax, by - ay
    length2 = dx * dx + dy * dy or 1
    x0, x1 = sorted((ax, bx))
    y0, y1 = sorted((ay, by))
    for y in range(int(y0 - width), int(y1 + width) + 1):
        for x in range(int(x0 - width), int(x1 + width) + 1):
            if not (0 <= x < TILE and 0 <= y < TILE) or not inside(x, y) or band_of(x, y) is not None:
                continue
            t = max(0.0, min(1.0, ((x - ax) * dx + (y - ay) * dy) / length2))
            px, py = ax + t * dx, ay + t * dy
            if (x - px) ** 2 + (y - py) ** 2 <= (width / 2) ** 2:
                grid[y][x] = SOLID
                overlay[(x, y)] = colors[material]


def place_plank(grid, overlay, colors, material, inside, x0, x1, y, land_y, thickness=5, post_w=6):
    """A plank `thickness` cells thick from x0 to x1, held up by a post
    of the same material down to `land_y` -- a water line or a floor,
    never ending in the air."""
    fit_rect(grid, overlay, colors, material, inside, x0, x1, y, y + thickness)
    pcx = (x0 + x1) // 2
    lo, hi = sorted((y + thickness, land_y))
    fit_rect(grid, overlay, colors, material, inside, pcx - post_w // 2, pcx + post_w // 2, lo, hi)


def place_ladder(grid, overlay, colors, material, inside, x, y0, y1, width=5, rung=18):
    fit_rect(grid, overlay, colors, material, inside, x - width // 2, x + width // 2, y0, y1)
    yy = y0
    while yy < y1:
        fit_rect(grid, overlay, colors, material, inside, x - width, x + width, int(yy), int(yy) + 3)
        yy += rung


def place_bracket_ledge(grid, overlay, colors, material, inside, wall_x, out, y, thickness, from_west, into=10):
    """A ledge `thickness` thick, running `out` cells from the wall at
    `wall_x`, held on two brackets driven `into` cells back into the
    wall, and a strut under it, from low on the wall out to the far
    end -- never across the platform's own face, or it reads as a
    crossed stick instead of something to stand on."""
    if from_west:
        x0, x1 = wall_x, wall_x + out
    else:
        x0, x1 = wall_x - out, wall_x
    fit_rect(grid, overlay, colors, material, inside, x0, x1, y, y + thickness)
    for bx in (x0 + out * 0.15, x0 + out * 0.75) if from_west else (x1 - out * 0.15, x1 - out * 0.75):
        if from_west:
            bx0, bx1 = wall_x - into, wall_x
        else:
            bx0, bx1 = wall_x, wall_x + into
        fit_rect(grid, overlay, colors, material, inside, int(bx0), int(bx1), y - 6, y)
    far_x = x1 if from_west else x0
    place_brace(grid, overlay, colors, material, inside, wall_x, y + thickness + 24, far_x, y + thickness + 1)


def in_mound(x, y, cx, floor_y, half_w, height):
    """A rounded mound sitting on the floor at `floor_y`, not a flat
    half-disc floating above it."""
    if y > floor_y:
        return False
    nx, ny = (x - cx) / half_w, (floor_y - y) / height
    return nx * nx + ny * ny <= 1.0


def place_coal_bin(grid, overlay, colors, inside, cx, floor_y, half_w, height, wall=6):
    """A three-sided Wood bin on the floor, open at the top, filled
    with Coal: dark against black air is not there at all unless a
    lighter material frames it, and the bin's own walls are that
    frame."""
    x0, x1 = cx - half_w, cx + half_w
    top = floor_y - height
    fit_rect(grid, overlay, colors, "Coal", inside, x0, x1, top, floor_y)
    fit_rect(grid, overlay, colors, "Wood", inside, x0 - wall, x0, top - wall, floor_y)
    fit_rect(grid, overlay, colors, "Wood", inside, x1, x1 + wall, top - wall, floor_y)
    fit_rect(grid, overlay, colors, "Wood", inside, x0 - wall, x1 + wall, top - wall, top)


def in_bowl(x, y, cx, rim_y, rx, ry):
    if y < rim_y:
        return False
    nx, ny = (x - cx) / rx, (y - rim_y) / ry
    return nx * nx + ny * ny <= 1.0


def carve_bowl_pit(grid, overlay, colors, inside, cx, rim_y, half_w, depth, liquid, rim=6, lip=7):
    """A pit sunk into the floor: a rounded bowl lined in Steel, an
    Obsidian lip -- a rim course following the top edge on both sides,
    not a bar across it -- and the liquid filled flat below that rim.
    A hole in the floor with fire in it, not an orange box."""
    outer_rx, outer_ry = half_w + rim, depth + rim
    for y in range(rim_y - 2, rim_y + outer_ry + 3):
        for x in range(cx - outer_rx - 2, cx + outer_rx + 3):
            if not (0 <= x < TILE and 0 <= y < TILE) or not inside(x, y):
                continue
            if in_bowl(x, y, cx, rim_y, half_w, depth):
                grid[y][x] = OPEN
                if band_of(x, y) is None:
                    overlay[(x, y)] = colors[liquid]
            elif in_bowl(x, y, cx, rim_y, outer_rx, outer_ry):
                grid[y][x] = SOLID
                if band_of(x, y) is None:
                    overlay[(x, y)] = colors["Steel"]
    for y in range(rim_y, rim_y + lip):
        for x in range(cx - outer_rx - 2, cx + outer_rx + 3):
            if 0 <= x < TILE and 0 <= y < TILE and inside(x, y) and band_of(x, y) is None:
                if overlay.get((x, y)) == colors["Steel"]:
                    overlay[(x, y)] = colors["Obsidian"]


def carve_gold_seam(grid, overlay, colors, x0, x1, y_base, amp, rng):
    """A seam of gold, 8 to 14 cells thick, over 200 long, wandering
    through the dirt above the shell and dipping to bite into the
    packing wherever the wander runs low. It may only mark cells the
    grid already holds as solid, so it never crosses open air."""
    phase = rng.uniform(0, 2 * math.pi)
    for x in range(x0, x1):
        cy = y_base + int(amp * math.sin(phase + x * 0.02) + amp * 0.4 * math.sin(phase * 1.7 + x * 0.05))
        th = 8 + int(3 * (1 + math.sin(phase * 2.3 + x * 0.03)))
        for y in range(cy - th // 2, cy + th // 2):
            if 0 <= x < TILE and 0 <= y < TILE and grid[y][x] == SOLID and band_of(x, y) is None:
                overlay[(x, y)] = colors["Gold"]


def paint_thick_line(overlay, colors, material, ax, ay, bx, by, width):
    dx, dy = bx - ax, by - ay
    length2 = dx * dx + dy * dy or 1
    x0, x1 = sorted((ax, bx))
    y0, y1 = sorted((ay, by))
    for y in range(int(y0 - width), int(y1 + width) + 1):
        for x in range(int(x0 - width), int(x1 + width) + 1):
            if not (0 <= x < TILE and 0 <= y < TILE) or band_of(x, y) is not None:
                continue
            t = max(0.0, min(1.0, ((x - ax) * dx + (y - ay) * dy) / length2))
            px, py = ax + t * dx, ay + t * dy
            if (x - px) ** 2 + (y - py) ** 2 <= (width / 2) ** 2:
                overlay[(x, y)] = colors[material]


def place_glyph(overlay, colors, glyph_material, cx, cy, kind, size=25):
    """One maker's mark, etched flush on the wall face -- a down
    triangle for water, an up one for fire, a circle with a dot
    otherwise. A few strokes, `size` * 2 across and 6 wide, and nothing
    else: no plaque standing proud, just the mark."""
    if kind == "down":
        pts = ((cx - size, cy - size), (cx + size, cy - size), (cx, cy + size))
    elif kind == "up":
        pts = ((cx - size, cy + size), (cx + size, cy + size), (cx, cy - size))
    else:
        pts = None
    if pts:
        for a, b in zip(pts, pts[1:] + pts[:1]):
            paint_thick_line(overlay, colors, glyph_material, a[0], a[1], b[0], b[1], 6)
    else:
        steps = 24
        ring = [
            (cx + size * math.cos(2 * math.pi * i / steps), cy + size * math.sin(2 * math.pi * i / steps))
            for i in range(steps)
        ]
        for a, b in zip(ring, ring[1:] + ring[:1]):
            paint_thick_line(overlay, colors, glyph_material, a[0], a[1], b[0], b[1], 6)
        for y in range(cy - 6, cy + 6):
            for x in range(cx - 6, cx + 6):
                if (x - cx) ** 2 + (y - cy) ** 2 <= 36 and band_of(x, y) is None:
                    overlay[(x, y)] = colors[glyph_material]


def scatter_rubble(grid, overlay, colors, inside, floor_y, x0, x1, rng, count=12):
    """A dozen lumps of Gravel and Rock on the floor: a floor that is a
    perfect line is the last thing that says drawn."""
    for _ in range(count):
        cx = rng.randint(x0, x1)
        w = rng.randint(2, 5)
        h = rng.randint(4, 10)
        mat = "Gravel" if rng.random() < 0.5 else "Rock"
        fit_rect(grid, overlay, colors, mat, inside, cx - w, cx + w, floor_y - h, floor_y)


def room_cistern(grid, rng, colors):
    """coalmine_1111_1: the Cistern. See the module docstring."""
    x0, x1, y0, y1 = 105, 405, 106, 406
    top_rx = bot_rx = 150
    top_ry = bot_ry = 80
    overlay = {}
    inside = build_shell(grid, overlay, colors, "Steel", rng, x0, x1, y0, y1, top_rx, top_ry, bot_rx, bot_ry)

    for side in "NESW":
        near, far, wall_at = {
            "N": (y0 - SHELL_T - 6, y0 + 30, y0), "S": (y1 + SHELL_T + 6, y1 - 30, y1),
            "W": (x0 - SHELL_T - 6, x0 + 30, x0), "E": (x1 + SHELL_T + 6, x1 - 30, x1),
        }[side]
        cut_doorway(grid, overlay, colors, "Steel", side, near, far, wall_at)
        carve_mouth_tunnel(grid, rng, side, x0, x1, y0, y1, top_rx, top_ry, bot_rx, bot_ry)

    place_ribs(grid, overlay, colors, "Steel", x0, x1, y0, y1, top_ry, bot_ry, rng,
               skip=((MOUTH_LO - 4, MOUTH_HI + 4),))

    # the tank's own courses: a rivet seam and Rock hoops banding it
    rivet_wall(overlay, colors, "Steel", "Gravel", "Rock", x0, x1, y0, y1, top_rx, top_ry, bot_rx, bot_ry)

    # the tank's own rounded bottom is the basin: already round, already
    # steel-lined by the wall, so it only needs filling to a flat level
    level = 345
    for y in range(level, y1 + bot_ry + 4):
        for x in range(x0 - bot_rx - 4, x1 + bot_rx + 4):
            if inside(x, y):
                if band_of(x, y) is None:
                    overlay[(x, y)] = colors["Water"]

    # two wood planks on posts down to the water, staggered, with a
    # gap over the middle so the north doorway drops a player into it
    place_plank(grid, overlay, colors, "Wood", inside, 130, 235, 235, level)
    place_plank(grid, overlay, colors, "Wood", inside, 275, 390, 275, level)

    # a wood ladder down the east wall, drop shaft to the water, so the
    # tank can be climbed out of
    place_ladder(grid, overlay, colors, "Wood", inside, x1 - WALL_T - 10, 200, level)

    # a seam of gold, wide and long, wandering the dirt above the tank
    # and biting into the packing where it dips low
    carve_gold_seam(grid, overlay, colors, x0 - 60, x1 + 60, y0 - SHELL_T - 30, 22, rng)

    # the maker's mark, on a clear span of wall below the planks and
    # well clear of the west doorway's own jamb
    place_glyph(overlay, colors, "Obsidian", x0 + WALL_T + 20, 330, "down")

    scatter_rubble(grid, overlay, colors, inside, level - 2, x0 + 20, 150, rng, count=4)

    return overlay


def room_magazine(grid, rng, colors):
    """coalmine_0101_1: the Magazine. See the module docstring."""
    x0, x1, y0, y1 = 76, 436, 125, 410
    top_rx, top_ry = (x1 - x0) // 2, 55
    bot_rx = bot_ry = 24
    overlay = {}
    inside = build_shell(grid, overlay, colors, "Rock", rng, x0, x1, y0, y1, top_rx, top_ry, bot_rx, bot_ry)

    # coursed masonry over the whole shell -- the largest single change
    # a wall this size can carry
    margin = int(SHELL_T + max(top_ry, bot_ry) + 10)
    course_masonry(overlay, colors, "Rock", "Gravel", x0 - margin, x1 + margin, y0 - margin, y1 + margin)

    for side in "EW":
        near, far, wall_at = {"W": (x0 - SHELL_T - 6, x0 + 30, x0), "E": (x1 + SHELL_T + 6, x1 - 30, x1)}[side]
        cut_doorway(grid, overlay, colors, "Rock", side, near, far, wall_at)
        carve_mouth_tunnel(grid, rng, side, x0, x1, y0, y1, top_rx, top_ry, bot_rx, bot_ry)

    door_span = (MOUTH_LO - 4, MOUTH_HI + 4)
    place_ribs(grid, overlay, colors, "Rock", x0, x1, y0, y1, top_ry, bot_ry, rng, skip=(door_span,))

    # the timber frame, entirely inside the belt the doorway also lives
    # in: posts floor to lintel, a brace in the top corner of every bay
    FX0, FX1 = x0 + 24, x1 - 24
    FLOOR = 382
    LY0, LY1 = 184, 200   # the lintel

    # the lane comes first: a clear run the whole length of the hall,
    # door to door, far over 30 cells tall. The floor stops short of
    # the end walls by the same margin the beam does, so the space
    # under it is not a sealed box either -- it opens to the same gap
    # at each end that the loft above the beam does.
    fit_rect(grid, overlay, colors, "Rock", inside, FX0, FX1, FLOOR, FLOOR + 20)
    course_masonry(overlay, colors, "Rock", "Gravel", x0, x1, FLOOR, FLOOR + 20)

    # the beam, hung off the lane rather than standing in it: carried
    # at the two ends only, by a short post against each end wall above
    # its doorway, and along its length by struts up into the ceiling
    # and corbels off it. Nothing here reaches down anywhere near the
    # floor, so no bay is ever a closed box.
    door_top = (MOUTH_LO + MOUTH_HI) // 2 - 36
    fit_rect(grid, overlay, colors, "Wood", inside, FX0, FX1, LY0, LY1)
    fit_rect(grid, overlay, colors, "Wood", inside, x0 + WALL_T, x0 + WALL_T + 16, LY1, door_top - 4)
    fit_rect(grid, overlay, colors, "Wood", inside, x1 - WALL_T - 16, x1 - WALL_T, LY1, door_top - 4)

    hangers = [FX0 + (FX1 - FX0) * (i + 1) // 6 for i in range(5)]
    for i, hx in enumerate(hangers):
        if i % 2 == 0:
            place_brace(grid, overlay, colors, "Wood", inside, hx, LY0, hx + 22, LY0 - 28)
        else:
            fit_rect(grid, overlay, colors, "Wood", inside, hx - 6, hx + 6, LY0 - 14, LY0)

    # the bins, the trough and the crates: floor furniture only, well
    # short of the beam, so the lane above every one of them stays
    # clear the whole length of the hall
    bay_mid = [FX0 + (FX1 - FX0) * (2 * i + 1) // 10 for i in range(5)]

    bay0 = bay_mid[0]
    fit_rect(grid, overlay, colors, "Steel", inside, bay0 - 45, bay0 + 45, FLOOR - 18, FLOOR - 8)
    fit_rect(grid, overlay, colors, "Oil", inside, bay0 - 41, bay0 + 41, FLOOR - 14, FLOOR - 8)

    place_coal_bin(grid, overlay, colors, inside, bay_mid[1], FLOOR, 22, 26)
    place_coal_bin(grid, overlay, colors, inside, bay_mid[2], FLOOR, 22, 26)

    bay4 = bay_mid[4]
    fit_rect(grid, overlay, colors, "Wood", inside, bay4 - 34, bay4 + 34, FLOOR - 70, FLOOR - 64)
    for wx0, wx1 in ((bay4 - 34, bay4 - 30), (bay4 + 30, bay4 + 34)):
        fit_rect(grid, overlay, colors, "Wood", inside, wx0, wx1, FLOOR - 64, FLOOR)
    # four crates, not one slab: a Wood backing shows through as the
    # 4-cell gap between and around them. The partition stops well
    # short of the lintel, so it never closes the bay off.
    fit_rect(grid, overlay, colors, "Wood", inside, bay4 - 30, bay4 + 30, FLOOR - 64, FLOOR - 4)
    for cx0 in (bay4 - 26, bay4 + 2):
        for cy0 in (FLOOR - 56, FLOOR - 28):
            fit_rect(grid, overlay, colors, "Tnt", inside, cx0, cx0 + 24, cy0, cy0 + 24)

    # the maker's mark, on a clear span of the west wall: well below
    # the doorway and its jamb, well above the oil trough
    place_glyph(overlay, colors, "Steel", x0 - WALL_T + 18, 340, "circle", size=18)

    scatter_rubble(grid, overlay, colors, inside, FLOOR - 2, bay_mid[2] + 20, bay4 - 40, rng, count=8)

    return overlay


def room_well(grid, rng, colors):
    """coalmine_1010_1: the Well. See the module docstring."""
    x0, x1, y0, y1 = 96, 416, 20, 492
    top_rx = bot_rx = (x1 - x0) // 2
    top_ry = bot_ry = 90
    overlay = {}
    inside = build_shell(grid, overlay, colors, "Rock", rng, x0, x1, y0, y1, top_rx, top_ry, bot_rx, bot_ry)

    margin = int(SHELL_T + max(top_ry, bot_ry) + 10)
    course_masonry(overlay, colors, "Rock", "Gravel", x0 - margin, x1 + margin, y0 - margin, y1 + margin)

    for side in "NS":
        near, far, wall_at = {"N": (y0 - SHELL_T - 6, y0 + 30, y0), "S": (y1 + SHELL_T + 6, y1 - 30, y1)}[side]
        cut_doorway(grid, overlay, colors, "Rock", side, near, far, wall_at)
        carve_mouth_tunnel(grid, rng, side, x0, x1, y0, y1, top_rx, top_ry, bot_rx, bot_ry)

    place_ribs(grid, overlay, colors, "Rock", x0, x1, y0, y1, top_ry, bot_ry, rng)

    # steel hoops, banding the shaft at intervals
    for by in (150, 260, 350):
        for wx0, wx1 in ((x0 - WALL_T, x0), (x1, x1 + WALL_T)):
            room_paint(overlay, wx0, wx1, by, by + 12, colors["Steel"])

    # scaffold ledges on brackets, braced back to the wall, alternating
    # sides, staggered down; a ladder joins two of them
    ledges = ((130, True), (210, False), (290, True), (370, False))
    for y, from_west in ledges:
        wall_x = x0 + WALL_T if from_west else x1 - WALL_T
        place_bracket_ledge(grid, overlay, colors, "Wood", inside, wall_x, 95, y, 5, from_west)
    place_ladder(grid, overlay, colors, "Wood", inside, x0 + WALL_T + 14, 145, 285)

    # the shaft needs a floor, the full width of it: masonry, with the
    # south doorway cut through its clear (west) side, well clear of
    # the bowl sunk into its east side -- a hole in the ground with
    # fire in it, beside the way down, never under it or under nothing
    FLOOR = 400
    MC0, MC1 = MOUTH_LO - 4, MOUTH_HI + 4
    fit_rect(grid, overlay, colors, "Rock", inside, x0 + WALL_T, x1 - WALL_T, FLOOR, FLOOR + 16)
    course_masonry(overlay, colors, "Rock", "Gravel", x0, x1, FLOOR, FLOOR + 16)
    fit_open(grid, overlay, inside, MC0, MC1, FLOOR, FLOOR + 16)

    carve_bowl_pit(grid, overlay, colors, inside, 362, FLOOR, 38, 34, "Lava")

    place_glyph(overlay, colors, "Gold", x0 + WALL_T + 20, 210, "up")

    scatter_rubble(grid, overlay, colors, inside, FLOOR - 2, x0 + WALL_T, x0 + WALL_T + 120, rng, count=6)

    return overlay


# Keyed by biome name, signature and variant: only the Coalmine set has
# rooms so far, and only their second variant carries one.
ROOMS = {
    ("Coalmine", (1, 1, 1, 1), 1): room_cistern,
    ("Coalmine", (0, 1, 0, 1), 1): room_magazine,
    ("Coalmine", (1, 0, 1, 0), 1): room_well,
}

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
            room = ROOMS.get((name, sig, v))
            overlay = {} if room is None else room(grid, rng, colors)
            stamp(grid, sig, shape, corner_shape)
            pix = to_materials(grid, base, rock, ore, style["ore_rate"], rng)
            stamp(pix, sig, paint, corner_paint)
            for (x, y), color in overlay.items():
                pix[y][x] = color

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
