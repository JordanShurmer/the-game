#!/usr/bin/env python3
"""Paint the gallery: sixteen hand made rooms, one per thing the sandbox does.

    tools/seed_gallery.py           # draws data/rooms/gallery.png
    tools/seed_gallery.py --check   # holds the file on disk to the rules

The gallery is one biome region, `generator = image`. Its picture is
512x512, one pixel to one world cell, in material colors, read from
data/materials.txt. See docs/physics.md, "The gallery", for the room
table this draws from and the numbers this file must hold to.

WHAT IT DRAWS

A four by four grid of rooms. A room is 128 cells square, including
its bedrock wall, which is 4 cells thick on every side, so the space
inside a room is 120 by 120 (`GALLERY_ROOM` and `GALLERY_WALL` in
docs/physics.md). The whole canvas starts as bedrock, which gives the
outer border and every wall between rooms for free; each room then
carves its own 120x120 interior to air and paints its exhibit into it.

A door joins two rooms side by side: a gap cut through both rooms'
shared wall, at least PLAYER_BODY_H + 4 cells tall (18 here) and the
full 8 cells of wall it crosses. Its sill sits 20 cells above the
room floor. That height is chosen on purpose: the wizard's body is 13
cells and his jump clears about 26, so 20 is a step up he can jump
through, not a wall, and it sits above any pool a room's own reservoir
can raise on its floor, so a room's liquid never finds its own way
into the next one.

A shaft joins two rooms stacked one over the other: a hole at least
12 cells wide cut through the floor between them, ringed on the upper
room's side by a bedrock curb 20 cells tall. The curb is what keeps a
pool on the upper floor from draining down the hole; the hole itself
stays open so the wizard can still fall through it, or fly back up
through it on the jetpack.

Every room also gets a small bedrock plinth on its floor, so it reads
as a museum exhibit and not an empty box.

WHAT --check HOLDS THE FILE TO

  - Every pixel is a color some material in data/materials.txt claims.
  - Every room is reachable from the entrance. This is walked, not
    assumed: a flood fill over every cell whose material is not solid
    or not a powder (the same test `player_solid_at` makes) has to
    reach some pixel inside every room's 128x128 tile.
  - The outer border of the image is bedrock, apart from the entrance
    shaft in the top edge.

This tool draws fixed geometry from a table of room numbers; it does
not need a layout engine. It uses no randomness, so it draws the same
file byte for byte every time it runs.
"""

import argparse
import os
import struct
import sys
import zlib

MATERIALS_PATH = "data/materials.txt"
OUT_PATH = "data/rooms/gallery.png"

IMG      = 512  # the whole gallery, one region, cells_per_pixel in data/biomes.txt
GRID     = 4    # rooms across and down
ROOM     = 128  # GALLERY_ROOM: cells along one edge of a room, wall included
WALL     = 4    # GALLERY_WALL: cells of bedrock a room's own wall is thick
INTERIOR = ROOM - 2 * WALL  # 120: the space inside one room

DOOR_H    = 18  # a door is at least PLAYER_BODY_H (13) + 4 cells tall
DOOR_SILL = 20  # cells above the floor to the bottom of a door

SHAFT_W = 14  # a shaft is at least 12 cells wide; a little more for margin
CURB_H  = 20  # the bedrock curb beside a shaft, on the upper room's side

# The entrance shaft, in the top edge of the whole image. It has to
# reach at least 12 cells straight down from row 0: 4 to clear room
# 1's own north wall and 8 more into the open room behind it.
# world_find_mouth (src/player.odin) starts its search at world x 0
# and grows outward, so a shaft here is the mouth it is most likely to
# land beside.
ENTRANCE_X0, ENTRANCE_X1 = 4, 24   # [x0, x1)
ENTRANCE_DEPTH = 12

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


def read_materials():
    """Material name to (RGBA, state), from the one file that defines them."""
    materials = {}
    for name, fields in read_sections(path=MATERIALS_PATH).items():
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
    """Read the gallery back, whatever wrote it and whatever filters it used."""
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


# -------------------------------------------------------------- the rooms


def build_room_1(cv):
    """Entrance and powder: a hopper of sand pours and finds its angle.

    The entrance shaft comes down through the left of this room's own
    north wall, so the hopper sits well clear of it, over open floor.
    """
    r = Room(cv, 1)
    r.tank(55, 8, 95, 32, "Sand", hole_side="bottom", hole_lo=70, hole_hi=80)
    r.plinth(100)


def build_room_2(cv):
    """Water: a reservoir falls down a staircase of bedrock ledges and pools."""
    r = Room(cv, 2)
    r.tank(4, 4, 34, 24, "Water", hole_side="right", hole_lo=8, hole_hi=17)
    for i in range(5):
        ly = 30 + i * 16
        lx0 = 30 - i * 6
        r.box(lx0, ly, lx0 + 24, ly + 2, BEDROCK)
    r.plinth(100)


def build_room_3(cv):
    """Density: oil, water and toxic sludge pour down three chutes into
    one tall tank and settle in three layers by density (checked
    against data/materials.txt: Oil 0.85, Water 1.0, Toxic_Sludge 1.4)."""
    r = Room(cv, 3)
    r.box(4, 35, 115, 119, BEDROCK)
    r.box(9, 40, 110, 119, AIR)  # the one tall tank all three chutes feed
    for lx0, fill in ((10, "Oil"), (52, "Water"), (94, "Toxic_Sludge")):
        r.tank(lx0, 4, lx0 + 15, 20, fill, hole_side="bottom", hole_lo=lx0 + 5, hole_hi=lx0 + 10)
        r.box(lx0 + 5, 21, lx0 + 10, 39, AIR)  # the chute down to the tank, through its lid
    r.plinth(4, w=5, h=5)


def build_room_4(cv):
    """Gas: steam and smoke climb from their reservoirs and gather under
    a bedrock cap partway up the room."""
    r = Room(cv, 4)
    r.tank(10, 90, 40, 115, "Steam", hole_side="top", hole_lo=18, hole_hi=32)
    r.tank(75, 90, 105, 115, "Smoke", hole_side="top", hole_lo=83, hole_hi=97)
    r.box(4, 40, 115, 44, BEDROCK)  # the cap: solid, so the gas has to gather under it
    r.plinth(4, w=5, h=4)


def build_room_5(cv):
    """Fuel: a trail of oil the length of the floor, lit at one end. Kept
    to the left half of the floor, clear of the shaft down to room 9
    on the right, so nothing the fire needs drains away underneath it."""
    r = Room(cv, 5)
    r.box(6, 112, 78, 119, "Oil")
    r.box(6, 111, 7, 111, "Fire")  # one seed cell; it has a lifetime and finds the trail
    r.plinth(109)


def build_room_6(cv):
    """Wood: a wooden frame burns from a seed at its base, then falls as ash."""
    r = Room(cv, 6)
    r.box(30, 30, 90, 34, "Wood")   # lintel
    r.box(30, 30, 34, 119, "Wood")  # left post
    r.box(86, 30, 90, 119, "Wood")  # right post
    r.box(30, 118, 31, 118, "Fire")
    r.plinth(4, w=6, h=4)


def build_room_7(cv):
    """Quench: dig the sand plug and a reservoir of water falls onto a
    burning pool of oil below. The pool is already alight, with one
    seed cell, waiting for the water."""
    r = Room(cv, 7)
    r.tank(20, 8, 60, 30, "Water", hole_side="bottom", hole_lo=32, hole_hi=48)
    r.box(32, 31, 48, 44, "Sand")  # the plug: hardness 1, well under PLAYER_DIG_POWER
    r.box(10, 112, 109, 119, "Oil")
    r.box(38, 111, 39, 111, "Fire")
    r.plinth(100)


def build_room_8(cv):
    """Lava: dig the sand plug and water falls onto lava: obsidian and
    steam. Kept to the right of the room, clear of the shaft down from
    room 4 above, which lands left of center."""
    r = Room(cv, 8)
    r.tank(75, 8, 115, 30, "Water", hole_side="bottom", hole_lo=87, hole_hi=103)
    r.box(87, 31, 103, 44, "Sand")
    r.box(10, 100, 109, 119, "Lava")
    r.plinth(4, w=5, h=4)


def build_room_9(cv):
    """Ice: a lava pool with an ice block and a snow bank resting right
    against it, so the melt starts from gravity alone, no digging."""
    r = Room(cv, 9)
    r.box(10, 100, 109, 119, "Lava")
    r.box(20, 84, 35, 99, "Ice")   # sits directly on the lava
    r.box(70, 90, 95, 99, "Snow")  # piled against it too
    r.plinth(4, w=5, h=4)


def build_room_10(cv):
    """Acid: a pool eats down through dirt, sand and rock, and stops at
    steel. The layers are stacked in hardness order, softest on top,
    so the acid always meets what it can still dissolve next."""
    r = Room(cv, 10)
    r.box(4, 30, 115, 45, "Acid")
    r.box(4, 46, 115, 60, "Dirt")
    r.box(4, 61, 115, 75, "Sand")
    r.box(4, 76, 115, 95, "Rock")
    r.box(4, 96, 115, 119, "Steel")
    r.plinth(4, w=5, h=4)


def build_room_11(cv):
    """Gunpowder: a pile, unlit. Igniting it is a separate command, not
    baked into the picture."""
    r = Room(cv, 11)
    for i, (lo, hi) in enumerate(((40, 79), (30, 89), (20, 99), (10, 109))):
        r.box(lo, 100 + i * 5, hi, 104 + i * 5, "Gunpowder")
    r.plinth(4, w=5, h=4)


def build_room_12(cv):
    """Blast shadow: tnt behind a bedrock pillar, with a field of rock
    beyond it. Unlit; igniting it is a separate command. This room
    also carries the shaft down to room 16, so the pillar and rock
    field are kept clear of it."""
    r = Room(cv, 12)
    r.box(30, 104, 38, 119, "Tnt")
    r.box(50, 40, 57, 119, BEDROCK)  # the pillar: floor to well above the tnt.
    # Open air over the top of it (the room's own ceiling is 40 cells up
    # from here), so the wizard can still fly across the room; a ray
    # steep enough to clear it would already have spent its radius.
    r.box(66, 80, 92, 119, "Rock")   # the field: half in the pillar's shadow, half not
    r.plinth(4, w=5, h=4)


def build_room_13(cv):
    """Digging: eight vertical strips, softest to hardest. The wizard's
    dig power is 8, so he gets through dirt, sand, coal, wood and
    rock, and stops at obsidian."""
    r = Room(cv, 13)
    strips = ["Dirt", "Sand", "Coal", "Wood", "Rock", "Obsidian", "Steel", "Bedrock"]
    w = INTERIOR // len(strips)
    for i, name in enumerate(strips):
        lx0 = i * w
        lx1 = lx0 + w - 1 if i < len(strips) - 1 else INTERIOR - 1
        r.box(lx0, 0, lx1, r.floor, name)


def build_room_14(cv):
    """Collapse: a sand shelf on wooden struts, lit at their base. The
    struts burn away; the shelf is a powder, so it falls the moment
    nothing is left under it, with no support test needed."""
    r = Room(cv, 14)
    r.box(15, 55, 104, 63, "Sand")
    for lx in (20, 56, 92):
        r.box(lx, 64, lx + 5, r.floor, "Wood")
    r.box(20, r.floor - 1, 21, r.floor - 1, "Fire")
    r.plinth(4, w=5, h=4)


def build_room_15(cv):
    """Boxes: hollow crates of wood, ice, sand, gunpowder and steel, each
    on its own plinth."""
    r = Room(cv, 15)
    crates = ["Wood", "Ice", "Sand", "Gunpowder", "Steel"]
    lx = 4
    for name in crates:
        r.plinth(lx, w=18, h=4)
        r.hollow_box(lx + 2, r.floor - 4 - 16, lx + 15, r.floor - 4, name, wall=2)
        lx += 22


def build_room_16(cv):
    """Gas hazard: dig the plug and a pocket of flammable gas escapes
    into the room. The shaft down from room 12 lands on the right, so
    the reservoir sits clear of it, on the left."""
    r = Room(cv, 16)
    r.tank(10, 40, 60, 70, "Flammable_Gas", hole_side="bottom", hole_lo=25, hole_hi=45)
    r.box(25, 71, 45, 84, "Sand")
    r.plinth(4, w=5, h=4)


ROOM_BUILDERS = [
    build_room_1, build_room_2, build_room_3, build_room_4,
    build_room_5, build_room_6, build_room_7, build_room_8,
    build_room_9, build_room_10, build_room_11, build_room_12,
    build_room_13, build_room_14, build_room_15, build_room_16,
]

# Doors: every pair of rooms side by side in the same row.
DOORS = [(row, col) for row in range(GRID) for col in range(GRID - 1)]

# Shafts: the three links that make the museum read as one path, named
# in docs/physics.md. (col, top_row, where the hole starts in the
# upper room's local x)
SHAFTS = [
    (3, 0, 50),  # room 4 down to room 8, in the gap between the two gas tanks
    (0, 1, 90),  # room 5 down to room 9, clear of the oil trail
    (3, 2, 98),  # room 12 down to room 16, clear of its pillar and rock field
]


def paint():
    cv = Canvas()
    for build in ROOM_BUILDERS:
        build(cv)
    for row, col in DOORS:
        door(cv, row, col)
    for col, top_row, sx in SHAFTS:
        shaft(cv, col, top_row, sx)
    cv.fill(ENTRANCE_X0, 0, ENTRANCE_X1 - 1, ENTRANCE_DEPTH - 1, AIR)
    return cv


def render(cv, colors):
    pix = [[None] * IMG for _ in range(IMG)]
    for y in range(IMG):
        row = cv.cells[y]
        out = pix[y]
        for x in range(IMG):
            out[x] = colors[row[x]][0]
    return pix


# ----------------------------------------------------------------- the gate


def check(path):
    faults = []
    if not os.path.exists(path):
        return [f"{path} does not exist; run this tool with no arguments"]

    materials = read_materials()
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
        if ENTRANCE_X0 <= x < ENTRANCE_X1:
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
        start = (ENTRANCE_X0 + 1, 1)
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


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--check", action="store_true", help="hold the file on disk to the rules")
    parser.add_argument("--out", default=OUT_PATH)
    args = parser.parse_args()

    if not os.path.exists(MATERIALS_PATH):
        sys.exit(f"cannot read {MATERIALS_PATH}; run this from the repository root")

    if args.check:
        faults = check(args.out)
        for fault in faults:
            print(fault, file=sys.stderr)
        if faults:
            sys.exit(1)
        print(f"{args.out}: {IMG}x{IMG}, 16 rooms, every rule holds")
        return

    materials = read_materials()
    cv = paint()
    write_png(args.out, render(cv, materials))
    print(f"{args.out}: {IMG}x{IMG}, 16 rooms")


if __name__ == "__main__":
    main()
