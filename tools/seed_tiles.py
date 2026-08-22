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
    further."""
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


def cut_doorway(grid, overlay, colors, material, side, near, far, span=72, frame=8):
    """Cut a doorway through the shell on `side` ('N', 'E', 'S' or 'W'),
    clear from `near` to `far` along the wall's own depth, framed on
    both long edges in `material`, `frame` cells thick -- a jamb either
    side of an east or west doorway, a lintel above and a sill below a
    north or south one. `near` and `far` need not be ordered."""
    d0, d1 = sorted((near, far))
    mid = (MOUTH_LO + MOUTH_HI) // 2
    lo, hi = mid - span // 2, mid + span // 2
    if side in "NS":
        room_carve(grid, lo, hi, d0, d1, OPEN)
        room_erase(overlay, lo, hi, d0, d1)
        for a0, a1 in ((lo - frame, lo), (hi, hi + frame)):
            room_carve(grid, a0, a1, d0, d1, SOLID)
            room_paint(overlay, a0, a1, d0, d1, colors[material])
    else:
        room_carve(grid, d0, d1, lo, hi, OPEN)
        room_erase(overlay, d0, d1, lo, hi)
        for a0, a1 in ((lo - frame, lo), (hi, hi + frame)):
            room_carve(grid, d0, d1, a0, a1, SOLID)
            room_paint(overlay, d0, d1, a0, a1, colors[material])


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


def place_pillar(grid, overlay, colors, material, cx, y0, y1, shaft_w=14, cap_w=22, cap_h=10):
    """A pillar: a shaft `shaft_w` wide, with a base and a capital, each
    a block `cap_w` wide and `cap_h` tall, so it reads as built rather
    than as a bar standing in the middle of the floor."""
    room_carve(grid, cx - shaft_w // 2, cx + shaft_w // 2, y0, y1, SOLID)
    room_paint(overlay, cx - shaft_w // 2, cx + shaft_w // 2, y0, y1, colors[material])
    for cy0, cy1 in ((y0, y0 + cap_h), (y1 - cap_h, y1)):
        room_carve(grid, cx - cap_w // 2, cx + cap_w // 2, cy0, cy1, SOLID)
        room_paint(overlay, cx - cap_w // 2, cx + cap_w // 2, cy0, cy1, colors[material])


def place_plank(grid, overlay, colors, material, x0, x1, y, floor_y, thickness=5, post_w=6):
    """A plank `thickness` cells thick from x0 to x1, held up by a post
    of the same material down to `floor_y`."""
    room_carve(grid, x0, x1, y, y + thickness, SOLID)
    room_paint(overlay, x0, x1, y, y + thickness, colors[material])
    pcx = (x0 + x1) // 2
    lo, hi = sorted((y + thickness, floor_y))
    room_carve(grid, pcx - post_w // 2, pcx + post_w // 2, lo, hi, SOLID)
    room_paint(overlay, pcx - post_w // 2, pcx + post_w // 2, lo, hi, colors[material])


def place_bracket_ledge(grid, overlay, colors, material, wall_x, out, y, thickness, from_west, into=10):
    """A ledge `thickness` thick, running `out` cells from the wall at
    `wall_x`, held by a bracket driven `into` cells back into that
    wall."""
    if from_west:
        x0, x1 = wall_x, wall_x + out
    else:
        x0, x1 = wall_x - out, wall_x
    room_carve(grid, x0, x1, y, y + thickness, SOLID)
    room_paint(overlay, x0, x1, y, y + thickness, colors[material])
    if from_west:
        bx0, bx1 = wall_x - into, wall_x
    else:
        bx0, bx1 = wall_x, wall_x + into
    room_carve(grid, bx0, bx1, y - 6, y, SOLID)
    room_paint(overlay, bx0, bx1, y - 6, y, colors[material])


def in_mound(x, y, cx, floor_y, half_w, height):
    """A rounded mound sitting on the floor at `floor_y`, not a flat
    half-disc floating above it."""
    if y > floor_y:
        return False
    nx, ny = (x - cx) / half_w, (floor_y - y) / height
    return nx * nx + ny * ny <= 1.0


def place_coal_heap(grid, overlay, colors, cx, floor_y, half_w, height):
    for y in range(floor_y - height - 1, floor_y + 1):
        for x in range(cx - half_w - 1, cx + half_w + 1):
            if in_mound(x, y, cx, floor_y, half_w, height):
                grid[y][x] = SOLID
                if band_of(x, y) is None:
                    overlay[(x, y)] = colors["Coal"]


def carve_pit(grid, overlay, colors, x0, x1, y0, y1, liquid, rim=6, lip=16):
    """A pit sunk into the floor: a Steel rim around it, an Obsidian
    lip -- a rim course around the whole top edge, not a bar across it
    -- and the liquid filling it flat."""
    room_carve(grid, x0 - rim, x1 + rim, y0 - rim, y1 + rim, SOLID)
    room_paint(overlay, x0 - rim, x1 + rim, y0 - rim, y1 + rim, colors["Steel"])
    room_carve(grid, x0, x1, y0, y1, OPEN)
    room_paint(overlay, x0, x1, y0, y1, colors[liquid])
    room_paint(overlay, x0 - rim, x1 + rim, y0 - rim, y0 - rim + lip, colors["Obsidian"])


def paint_vein(grid, overlay, colors, x, y, length, rng, material):
    """A vein crawling through solid rock, the way `to_materials`
    already draws ore: a random walk that only marks a cell already
    solid. Starting it right at the wall's outer face is what exposes
    the vein there instead of leaving it a mark floating in open air."""
    for _ in range(length):
        if 0 <= x < TILE and 0 <= y < TILE and grid[y][x] == SOLID and band_of(x, y) is None:
            overlay[(x, y)] = colors[material]
        x += rng.randint(-1, 1)
        y += rng.randint(-1, 1)


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


def place_glyph(grid, overlay, colors, wall_material, glyph_material, cx, cy, kind, size=25):
    """One maker's mark, etched into a plaque set proud of the wall so
    it reads as part of the build: a down triangle for water, an up one
    for fire, a circle with a dot otherwise. A few strokes, `size` * 2
    across and 6 wide."""
    x0, x1 = cx - size - 8, cx + size + 8
    y0, y1 = cy - size - 8, cy + size + 8
    room_carve(grid, x0, x1, y0, y1, SOLID)
    room_paint(overlay, x0, x1, y0, y1, colors[wall_material])
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


def room_cistern(grid, rng, colors):
    """coalmine_1111_1: the Cistern. See the module docstring."""
    x0, x1, y0, y1 = 105, 405, 106, 406
    top_rx = bot_rx = 150
    top_ry = bot_ry = 80
    overlay = {}
    build_shell(grid, overlay, colors, "Steel", rng, x0, x1, y0, y1, top_rx, top_ry, bot_rx, bot_ry)

    for side in "NESW":
        near, far = {
            "N": (y0 - SHELL_T - 6, y0 + 30), "S": (y1 + SHELL_T + 6, y1 - 30),
            "W": (x0 - SHELL_T - 6, x0 + 30), "E": (x1 + SHELL_T + 6, x1 - 30),
        }[side]
        cut_doorway(grid, overlay, colors, "Steel", side, near, far)
        carve_mouth_tunnel(grid, rng, side, x0, x1, y0, y1, top_rx, top_ry, bot_rx, bot_ry)

    place_ribs(grid, overlay, colors, "Steel", x0, x1, y0, y1, top_ry, bot_ry, rng,
               skip=((MOUTH_LO - 4, MOUTH_HI + 4),))

    # the tank's own rounded bottom is the basin: already round, already
    # steel-lined by the wall, so it only needs filling to a flat level
    level = 345
    for y in range(level, y1 + bot_ry + 4):
        for x in range(x0 - bot_rx - 4, x1 + bot_rx + 4):
            if in_shell_shape(x, y, x0, x1, y0, y1, top_rx, top_ry, bot_rx, bot_ry):
                if band_of(x, y) is None:
                    overlay[(x, y)] = colors["Water"]

    # two wood planks on posts down to the water, staggered, with a
    # gap over the middle so the north doorway drops a player into it
    place_plank(grid, overlay, colors, "Wood", 130, 235, 235, level)
    place_plank(grid, overlay, colors, "Wood", 275, 390, 275, level)

    # a gold vein, crawling through the roof rock from where it meets
    # the wall's outer face
    paint_vein(grid, overlay, colors, x0 + 40, y0 - SHELL_T - 2, 220, rng, "Gold")
    paint_vein(grid, overlay, colors, x1 - 60, y0 - SHELL_T - 2, 180, rng, "Gold")

    # the maker's mark: a down-pointing triangle for water, on the wall
    # above the basin
    place_glyph(grid, overlay, colors, "Steel", "Obsidian", x0 - WALL_T + 25 + 8, 300, "down")

    return overlay


def room_magazine(grid, rng, colors):
    """coalmine_0101_1: the Magazine. See the module docstring."""
    x0, x1, y0, y1 = 76, 436, 150, 410
    top_rx, top_ry = (x1 - x0) // 2, 90
    bot_rx = bot_ry = 24
    overlay = {}
    build_shell(grid, overlay, colors, "Rock", rng, x0, x1, y0, y1, top_rx, top_ry, bot_rx, bot_ry)

    # coursing: thin gravel joints along the straight run of each wall,
    # so the shell reads as blocks, not one poured slab
    for wx in (x0 + WALL_T // 2, x1 - WALL_T // 2 - 1):
        yy = y0 + top_ry + 20
        while yy < y1 - bot_ry:
            room_paint(overlay, wx - WALL_T // 2, wx + WALL_T // 2 + 1, int(yy), int(yy) + 2, colors["Gravel"])
            yy += 26

    door_span = (MOUTH_LO - 4, MOUTH_HI + 4)
    for side in "EW":
        near, far = {"W": (x0 - SHELL_T - 6, x0 + 30), "E": (x1 + SHELL_T + 6, x1 - 30)}[side]
        cut_doorway(grid, overlay, colors, "Rock", side, near, far)
        carve_mouth_tunnel(grid, rng, side, x0, x1, y0, y1, top_rx, top_ry, bot_rx, bot_ry)

    place_ribs(grid, overlay, colors, "Rock", x0, x1, y0, y1, top_ry, bot_ry, rng, skip=(door_span,))

    # the timber frame: a beamed ceiling on four pillars, a hall tall
    # enough to be a hall
    FX0, FX1 = x0 + 24, x1 - 24
    FY0, FY1 = y0 + top_ry + 10, y1 - bot_ry
    room_carve(grid, FX0, FX1, FY0, FY0 + 16, SOLID)
    room_paint(overlay, FX0, FX1, FY0, FY0 + 16, colors["Wood"])
    pillars = [FX0 + (FX1 - FX0) * (i + 1) // 5 for i in range(4)]
    for px in pillars:
        place_pillar(grid, overlay, colors, "Wood", px, FY0 + 16, FY1, shaft_w=14, cap_w=22, cap_h=10)

    # a coal heap flanking each of the middle two pillars
    for px in pillars[1:3]:
        place_coal_heap(grid, overlay, colors, px - 34, FY1, 20, 26)

    # a steel trough of oil, in the first bay
    bay0 = (FX0 + pillars[0]) // 2
    room_carve(grid, bay0 - 24, bay0 + 24, FY1 - 16, FY1, OPEN)
    room_paint(overlay, bay0 - 28, bay0 + 28, FY1 - 20, FY1, colors["Steel"])
    room_paint(overlay, bay0 - 22, bay0 + 22, FY1 - 16, FY1, colors["Oil"])

    # the tnt cache, walled off behind wood, in the last bay
    bay4 = (pillars[3] + FX1) // 2
    room_carve(grid, bay4 - 20, bay4 + 20, FY0 + 16, FY1, OPEN)
    room_paint(overlay, bay4 - 20, bay4 + 20, FY0 + 16, FY1, colors["Tnt"])
    for wx0, wx1 in ((bay4 - 26, bay4 - 20), (bay4 + 20, bay4 + 26)):
        room_carve(grid, wx0, wx1, FY0 + 16, FY1, SOLID)
        room_paint(overlay, wx0, wx1, FY0 + 16, FY1, colors["Wood"])
    room_carve(grid, bay4 - 26, bay4 + 26, FY0 + 10, FY0 + 16, SOLID)
    room_paint(overlay, bay4 - 26, bay4 + 26, FY0 + 10, FY0 + 16, colors["Wood"])

    place_glyph(grid, overlay, colors, "Rock", "Steel", x1 + WALL_T - 25 - 8, 195, "circle")

    return overlay


def room_well(grid, rng, colors):
    """coalmine_1010_1: the Well. See the module docstring."""
    x0, x1, y0, y1 = 96, 416, 20, 492
    top_rx = bot_rx = (x1 - x0) // 2
    top_ry = bot_ry = 90
    overlay = {}
    build_shell(grid, overlay, colors, "Rock", rng, x0, x1, y0, y1, top_rx, top_ry, bot_rx, bot_ry)

    for side in "NS":
        near, far = {"N": (y0 - SHELL_T - 6, y0 + 30), "S": (y1 + SHELL_T + 6, y1 - 30)}[side]
        cut_doorway(grid, overlay, colors, "Rock", side, near, far)
        carve_mouth_tunnel(grid, rng, side, x0, x1, y0, y1, top_rx, top_ry, bot_rx, bot_ry)

    place_ribs(grid, overlay, colors, "Rock", x0, x1, y0, y1, top_ry, bot_ry, rng)

    # steel bands, hooping the shaft at intervals
    for by in (150, 260, 370):
        for wx0, wx1 in ((x0 - WALL_T, x0), (x1, x1 + WALL_T)):
            room_paint(overlay, wx0, wx1, by, by + 14, colors["Steel"])

    # scaffold ledges on brackets, alternating walls, staggered down
    for y, from_west in ((130, True), (210, False), (290, True), (370, False)):
        wall_x = x0 + WALL_T if from_west else x1 - WALL_T
        place_bracket_ledge(grid, overlay, colors, "Wood", wall_x, 95, y, 5, from_west)

    # the bottom: a clear rock ledge on one side, the lava pit on the
    # other, so the hazard is beside the way down, not blind under it
    FY = 440
    room_carve(grid, x0 + WALL_T, x0 + WALL_T + 130, FY, FY + 16, SOLID)
    room_paint(overlay, x0 + WALL_T, x0 + WALL_T + 130, FY, FY + 16, colors["Rock"])
    carve_pit(grid, overlay, colors, x1 - WALL_T - 110, x1 - WALL_T - 10, FY - 10, FY + 44, "Lava")

    place_glyph(grid, overlay, colors, "Rock", "Gold", x0 - WALL_T + 25 + 8, 210, "up")

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
