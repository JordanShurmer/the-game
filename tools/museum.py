"""The museum: the canvas, the room, the doors and the shafts, and the PNG
reader and writer that every hand painted gallery shares.

A gallery is a four by four grid of rooms, each `ROOM` cells square
including its bedrock wall, `WALL` cells thick on every side, so the
space inside a room is `INTERIOR` by `INTERIOR`. A door joins two rooms
side by side; a shaft joins two rooms stacked one over the other. See
docs/physics.md, "The gallery", for the numbers this holds to.

Three rules `check()` holds a finished gallery to:

  - Every pixel is a color some material in data/materials.txt claims.
  - Every room is reachable from the entrance. This is walked, not
    assumed: a flood fill over every cell whose material is not solid
    or not a powder (the same test `player_solid_at` makes) has to
    reach some pixel inside every room's tile.
  - The outer border of the image is bedrock, apart from the entrance
    shaft in the top edge.

This module draws no rooms of its own. A gallery script imports it,
supplies its own room table, and calls `run_cli` to get the same
`--check` gate and `--out` argument every gallery shares.
"""

import argparse
import os
import struct
import sys
import zlib

MATERIALS_PATH = "data/materials.txt"

IMG      = 512  # the whole gallery, one region, cells_per_pixel in data/biomes.txt
GRID     = 4    # rooms across and down
ROOM     = 128  # GALLERY_ROOM: cells along one edge of a room, wall included
WALL     = 4    # GALLERY_WALL: cells of bedrock a room's own wall is thick
INTERIOR = ROOM - 2 * WALL  # 120: the space inside one room

DOOR_H    = 18  # a door is at least PLAYER_BODY_H (13) + 4 cells tall
DOOR_SILL = 20  # cells above the floor to the bottom of a door

SHAFT_W = 14  # a shaft is at least 12 cells wide; a little more for margin
CURB_H  = 20  # the bedrock curb beside a shaft, on the upper room's side

AIR = "Air"
BEDROCK = "Bedrock"


# ------------------------------------------------------------ the data files


def read_sections(path):
    """The format materials.txt shares with biomes.txt: [Name] and key = value."""
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


def read_materials(path=MATERIALS_PATH):
    """Material name to (RGBA, state), from the one file that defines them."""
    materials = {}
    for name, fields in read_sections(path=path).items():
        if name == "Reactions":
            continue
        argb = int(fields.get("color", "0"), 0)
        rgba = (
            (argb >> 16) & 0xFF,
            (argb >> 8) & 0xFF,
            argb & 0xFF,
            (argb >> 24) & 0xFF,
        )
        materials[name] = (rgba, fields.get("state", "Solid"))
    return materials


# ------------------------------------------------------------------- the PNG
# Same writer and reader as tools/seed_tiles.py and tools/seed_wizard.py:
# struct and zlib only, and every PNG scanline filter handled on the way
# back in, because --check has to read whatever wrote the file.


def write_png(path, pix):
    height, width = len(pix), len(pix[0])
    raw = b"".join(
        b"\x00" + b"".join(struct.pack("BBBB", *pix[y][x]) for x in range(width))
        for y in range(height)
    )

    def chunk(tag, data):
        body = tag + data
        return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)

    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(raw, 9))
    png += chunk(b"IEND", b"")
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    open(path, "wb").write(png)


def read_png(path):
    """Read a gallery back, whatever wrote it and whatever filters it used."""
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
            width, height, depth, colour = struct.unpack(">IIBB", body[:10])
            if (depth, colour) != (8, 6):
                raise ValueError(f"{path} is not 8 bit RGBA")
        elif tag == b"IDAT":
            idat += body

    raw = zlib.decompress(idat)
    stride = width * 4
    rows, previous, at = [], bytearray(stride), 0
    for _ in range(height):
        kind, at = raw[at], at + 1
        line = bytearray(raw[at : at + stride])
        at += stride
        for x in range(stride):
            a = line[x - 4] if x >= 4 else 0
            b = previous[x]
            c = previous[x - 4] if x >= 4 else 0
            if kind == 1:
                line[x] = (line[x] + a) & 0xFF
            elif kind == 2:
                line[x] = (line[x] + b) & 0xFF
            elif kind == 3:
                line[x] = (line[x] + (a + b) // 2) & 0xFF
            elif kind == 4:
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                near = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                line[x] = (line[x] + near) & 0xFF
            elif kind != 0:
                raise ValueError(f"{path} uses scanline filter {kind}")
        rows.append([tuple(line[x * 4 : x * 4 + 4]) for x in range(width)])
        previous = line
    return width, height, rows


# --------------------------------------------------------------- the canvas


class Canvas:
    """A 512x512 grid of material names, addressed by world cell."""

    def __init__(self):
        self.cells = [[BEDROCK] * IMG for _ in range(IMG)]

    def set(self, x, y, name):
        self.cells[y][x] = name

    def fill(self, x0, y0, x1, y1, name):
        """Fill world cells [x0,x1] x [y0,y1], inclusive, clipped to the canvas."""
        for y in range(max(0, y0), min(IMG - 1, y1) + 1):
            row = self.cells[y]
            for x in range(max(0, x0), min(IMG - 1, x1) + 1):
                row[x] = name


def room_origin(n):
    """World (x, y) of the top left corner of room n, numbered 1..16 in
    reading order."""
    idx = n - 1
    col, row = idx % GRID, idx // GRID
    return col * ROOM, row * ROOM


def interior(n):
    """The interior of room n as a world rect (x0, y0, x1, y1), inclusive."""
    ox, oy = room_origin(n)
    return ox + WALL, oy + WALL, ox + ROOM - WALL - 1, oy + ROOM - WALL - 1


class Room:
    """One room, addressed in its own local coordinates.

    (0, 0) is the top left cell of the interior and (119, 119) is the
    bottom right, so every room's content is written the same way
    regardless of where the room sits in the grid. floor is the last
    row, the one a plinth or a pool floor sits on.
    """

    def __init__(self, cv, n):
        self.cv = cv
        self.n = n
        self.x0, self.y0, self.x1, self.y1 = interior(n)
        self.floor = INTERIOR - 1
        self.cv.fill(self.x0, self.y0, self.x1, self.y1, AIR)

    def w(self, lx, ly):
        return self.x0 + lx, self.y0 + ly

    def box(self, lx0, ly0, lx1, ly1, name):
        x0, y0 = self.w(lx0, ly0)
        x1, y1 = self.w(lx1, ly1)
        self.cv.fill(x0, y0, x1, y1, name)

    def hollow_box(self, lx0, ly0, lx1, ly1, name, wall=2):
        self.box(lx0, ly0, lx1, ly1, name)
        self.box(lx0 + wall, ly0 + wall, lx1 - wall, ly1 - wall, AIR)

    def plinth(self, lx0, w=8, h=4):
        """A small bedrock stand on the floor, so the room reads as an
        exhibit. lx0 is its left edge."""
        self.box(lx0, self.floor - h + 1, lx0 + w - 1, self.floor, BEDROCK)

    def tank(self, lx0, ly0, lx1, ly1, fill, wall=3, hole_side=None, hole_lo=0, hole_hi=0):
        """A bedrock walled reservoir, filled with one material, with an
        optional hole cut through one wall so the fill can escape.

        This is the whole "no emitter material" idea from docs/physics.md:
        a reservoir behind a wall with a hole in it is a tap.
        """
        self.box(lx0, ly0, lx1, ly1, BEDROCK)
        self.box(lx0 + wall, ly0 + wall, lx1 - wall, ly1 - wall, fill)
        if hole_side == "bottom":
            self.box(hole_lo, ly1 - wall + 1, hole_hi, ly1, AIR)
        elif hole_side == "top":
            self.box(hole_lo, ly0, hole_hi, ly0 + wall - 1, AIR)
        elif hole_side == "left":
            self.box(lx0, hole_lo, lx0 + wall - 1, hole_hi, AIR)
        elif hole_side == "right":
            self.box(lx1 - wall + 1, hole_lo, lx1, hole_hi, AIR)


# ------------------------------------------------------------------- doors


def door(cv, row, left_col):
    """A gap between the room at (row, left_col) and the room to its
    east, cut through both rooms' walls at once.

    The sill sits DOOR_SILL cells above the shared floor, and the gap
    is DOOR_H cells tall: a step up for the wizard, not a wall, and
    high enough above any pool a room's own reservoir can raise that a
    pool never finds its own way through it.
    """
    ox = left_col * ROOM
    floor_y = row * ROOM + ROOM - WALL  # the world row just past the interior: the floor's surface
    bottom = floor_y - DOOR_SILL
    top = bottom - DOOR_H + 1
    cv.fill(ox + ROOM - WALL, top, ox + ROOM + WALL - 1, bottom, AIR)


def shaft(cv, col, top_row, sx_local):
    """A hole between the room at (top_row, col) and the room below it,
    plus the curb that keeps the upper room's floor from draining
    down it.

    sx_local is where the hole starts, in the upper room's local
    (interior) x. The curb stands directly beside the hole, on the
    upper room's floor, so a pool on that floor meets a wall before it
    meets the hole.
    """
    ox = col * ROOM
    oy_top = top_row * ROOM
    hole_x0 = ox + WALL + sx_local
    hole_x1 = hole_x0 + SHAFT_W - 1

    # The hole itself: straight through the shared wall band.
    cv.fill(hole_x0, oy_top + ROOM - WALL, hole_x1, oy_top + ROOM + WALL - 1, AIR)

    # The curb: bedrock flanking the hole, standing CURB_H cells tall
    # on the upper room's floor.
    floor_y = oy_top + ROOM - WALL - 1
    curb_y0 = floor_y - CURB_H + 1
    cv.fill(hole_x0 - WALL, curb_y0, hole_x0 - 1, floor_y, BEDROCK)
    cv.fill(hole_x1 + 1, curb_y0, hole_x1 + WALL, floor_y, BEDROCK)


def render(cv, colors):
    pix = [[None] * IMG for _ in range(IMG)]
    for y in range(IMG):
        row = cv.cells[y]
        out = pix[y]
        for x in range(IMG):
            out[x] = colors[row[x]][0]
    return pix


# ----------------------------------------------------------------- the gate


def check(path, entrance_x0, entrance_x1, materials_path=MATERIALS_PATH):
    faults = []
    if not os.path.exists(path):
        return [f"{path} does not exist; run this tool with no arguments"]

    materials = read_materials(materials_path)
    by_color = {}
    for name, (rgba, state) in materials.items():
        argb = (rgba[3] << 24) | (rgba[0] << 16) | (rgba[1] << 8) | rgba[2]
        by_color[argb] = (name, state)

    width, height, rows = read_png(path)
    if (width, height) != (IMG, IMG):
        return [f"{path} is {width}x{height}, and the gallery must be {IMG}x{IMG}"]

    # Rule 1: every pixel is a color some material claims.
    passable = [[False] * width for _ in range(height)]
    names = [[None] * width for _ in range(height)]
    bad_pixels = 0
    for y in range(height):
        row = rows[y]
        for x in range(width):
            r, g, b, a = row[x]
            argb = (a << 24) | (r << 16) | (g << 8) | b
            hit = by_color.get(argb)
            if hit is None:
                bad_pixels += 1
                if bad_pixels <= 5:
                    faults.append(f"pixel ({x},{y}) is color {argb:08X}, which no material claims")
                continue
            name, state = hit
            names[y][x] = name
            passable[y][x] = state not in ("Solid", "Powder")
    if bad_pixels > 5:
        faults.append(f"... and {bad_pixels - 5} more unmatched pixels")

    # Rule 3: the outer border is bedrock, apart from the entrance.
    for x in range(width):
        if entrance_x0 <= x < entrance_x1:
            continue
        if names[0][x] != BEDROCK:
            faults.append(f"top border at x={x} is {names[0][x]}, not Bedrock")
    for x in range(width):
        if names[height - 1][x] != BEDROCK:
            faults.append(f"bottom border at x={x} is {names[height - 1][x]}, not Bedrock")
    for y in range(height):
        if names[y][0] != BEDROCK:
            faults.append(f"left border at y={y} is {names[y][0]}, not Bedrock")
        if names[y][width - 1] != BEDROCK:
            faults.append(f"right border at y={y} is {names[y][width - 1]}, not Bedrock")

    # Rule 2: every room is reachable from the entrance. Walked, not
    # assumed: a flood fill over passable cells, the same test
    # player_solid_at makes (not Solid, not Powder).
    if bad_pixels == 0:
        start = (entrance_x0 + 1, 1)
        seen = [[False] * width for _ in range(height)]
        stack = [start]
        seen[start[1]][start[0]] = True
        while stack:
            x, y = stack.pop()
            for nx, ny in ((x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)):
                if 0 <= nx < width and 0 <= ny < height and not seen[ny][nx] and passable[ny][nx]:
                    seen[ny][nx] = True
                    stack.append((nx, ny))

        for n in range(1, GRID * GRID + 1):
            ox, oy = room_origin(n)
            reached = any(
                seen[y][x] for y in range(oy, oy + ROOM) for x in range(ox, ox + ROOM)
            )
            if not reached:
                faults.append(f"room {n} at tile ({ox},{oy}) is not reachable from the entrance")

    return faults


# ------------------------------------------------------------------- the CLI


def run_cli(description, out_path, paint, entrance_x0, entrance_x1):
    """The argument parsing every gallery script shares: draw the file, or
    hold the one on disk to the rules with --check."""
    parser = argparse.ArgumentParser(description=description, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--check", action="store_true", help="hold the file on disk to the rules")
    parser.add_argument("--out", default=out_path)
    args = parser.parse_args()

    if not os.path.exists(MATERIALS_PATH):
        sys.exit(f"cannot read {MATERIALS_PATH}; run this from the repository root")

    if args.check:
        faults = check(args.out, entrance_x0, entrance_x1)
        for fault in faults:
            print(fault, file=sys.stderr)
        if faults:
            sys.exit(1)
        print(f"{args.out}: {IMG}x{IMG}, {GRID*GRID} rooms, every rule holds")
        return

    materials = read_materials()
    cv = paint()
    write_png(args.out, render(cv, materials))
    print(f"{args.out}: {IMG}x{IMG}, {GRID*GRID} rooms")
