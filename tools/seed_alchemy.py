#!/usr/bin/env python3
"""Paint the alchemy gallery: the poison, the water, and what the two make
of each other, six rooms of it, east of the physics gallery.

    tools/seed_alchemy.py           # draws data/rooms/alchemy.png
    tools/seed_alchemy.py --check   # holds the file on disk to the rules

Same shape as tools/seed_gallery.py, sharing tools/museum.py: sixteen
rooms in a four by four grid. The first six are the alchemy; the other
ten are empty halls with a plinth, room for what comes next. See
docs/alchemy.md, "The alchemy gallery", for the room table this draws
from.

Room 6, "the dark", is sealed from its row neighbours on purpose: no
door to room 5 or room 7, so nothing either room lights can be seen
from it. It reaches the rest of the museum through a shaft down to
room 10 instead, an empty hall with no light of its own.

This tool draws fixed geometry from a table of room numbers; it uses
no randomness, so it draws the same file byte for byte every time it
runs.
"""

from museum import GRID, AIR, BEDROCK, Canvas, Room, door, shaft, run_cli

OUT_PATH = "data/rooms/alchemy.png"

# The entrance shaft, in the top edge of room 1, the same way the
# physics gallery's is.
ENTRANCE_X0, ENTRANCE_X1 = 4, 24   # [x0, x1)
ENTRANCE_DEPTH = 12


# -------------------------------------------------------------- the rooms


def build_room_1(cv):
    """Attor: a tank of poison pours down a stair into a basin. No water,
    no light: this is the liquid on its own."""
    r = Room(cv, 1)
    # Shifted clear of the entrance shaft in this room's own north wall.
    r.tank(44, 4, 74, 24, "Attor", hole_side="right", hole_lo=8, hole_hi=17)
    for i in range(5):
        ly = 30 + i * 16
        lx0 = 70 - i * 6
        r.box(lx0, ly, lx0 + 24, ly + 2, BEDROCK)
    r.plinth(100)


def build_room_2(cv):
    """The mix: an Attor tap and a water tap side by side, so the two
    streams touch as they fall and react the whole way down. The
    sparks flash over the basin and Smylt pools under them."""
    r = Room(cv, 2)
    r.tank(10, 6, 59, 28, "Attor", wall=3, hole_side="bottom", hole_lo=54, hole_hi=59)
    r.tank(60, 6, 109, 28, "Water", wall=3, hole_side="bottom", hole_lo=60, hole_hi=65)
    r.box(20, 90, 99, 119, BEDROCK)
    r.box(24, 94, 95, 119, AIR)
    r.plinth(4, w=5, h=4)


def build_room_3(cv):
    """The measure: three parts Attor sealed over three parts water in a
    graduated tube, against a bedrock scale. What is left stands at
    four, so the scale carries a tick at the 4-of-6 mark."""
    r = Room(cv, 3)
    x0, x1 = 45, 58
    y0, y1 = 8, 107  # 100 cells: a tall, narrow, sealed column
    r.box(x0 - 4, y0 - 4, x1 + 4, y1 + 4, BEDROCK)
    r.box(x0, y0, x1, y1, AIR)

    half = (y1 - y0 + 1) // 2
    r.box(x0, y0, x1, y0 + half - 1, "Attor")
    r.box(x0, y0 + half, x1, y1, "Water")

    # The scale: a bedrock strip beside the tube, ticked at the 4-of-6
    # mark (measured up from the floor of the tube).
    height = y1 - y0 + 1
    scale_x = x1 + 8
    r.box(scale_x, y0, scale_x + 2, y1, BEDROCK)
    mark_y = y1 - (height * 4 // 6)
    r.box(scale_x, mark_y, scale_x + 5, mark_y + 1, BEDROCK)  # a tick, out to the right
    r.plinth(4, w=5, h=5)


def build_room_4(cv):
    """The rain: water drips through a perforated bedrock ceiling into a
    shallow pool of Attor: a slow, unending field of sparks."""
    r = Room(cv, 4)
    r.tank(4, 4, 115, 26, "Water", wall=3, hole_side=None)
    for hx in (20, 45, 70, 95):
        r.box(hx, 23, hx + 2, 26, AIR)
    r.box(4, 100, 115, 119, "Attor")
    r.plinth(4, w=5, h=4)


def build_room_5(cv):
    """Layers: oil, water, Smylt and Attor pour down one narrow column
    and settle in four bands, in the order the densities say (Oil
    0.85, Water 1.0, Smylt 1.05, Attor 1.25). The reservoir above holds
    them stacked out of order on purpose: the pour down the column is
    what sorts them, the same gravity that starts every room here."""
    r = Room(cv, 5)
    x0, x1 = 50, 69
    r.box(x0 - 4, 4, x1 + 4, r.floor, BEDROCK)
    r.box(x0, 4, x1, r.floor, AIR)

    r.tank(20, 4, 99, 40, "Oil", wall=3, hole_side="bottom", hole_lo=x0 + 2, hole_hi=x1 - 2)
    order = ["Attor", "Smylt", "Oil", "Water"]
    band = (37 - 7 + 1) // len(order)
    for i, fill in enumerate(order):
        r.box(23, 7 + i * band, 96, 7 + (i + 1) * band - 1, fill)
    r.plinth(4, w=5, h=4)


def build_room_6(cv):
    """The dark: a sealed chamber with one drip in the middle of it. Both
    the reservoir and the pool it feeds are wholly inside this room's
    own walls, and the room has no door to either neighbour, so the
    sparks are the only light there is."""
    r = Room(cv, 6)
    # A one cell hole and a long fall to the pool below, so the water
    # comes down as a drip through open air rather than a poured mass.
    # Kept to the left, clear of the shaft down to room 10 in the
    # middle of the floor, so neither the drip nor the pool it feeds
    # can find its own way down that hole.
    r.tank(15, 4, 42, 50, "Water", wall=3, hole_side="bottom", hole_lo=27, hole_hi=27)
    # A walled basin, open at the top for the drip to fall into: what
    # the drip and the reaction leave has nowhere to spread but here,
    # however tall it stacks, so it can never spill toward the shaft.
    r.box(6, 65, 9, 119, BEDROCK)
    r.box(41, 65, 44, 119, BEDROCK)
    r.box(6, 116, 44, 119, BEDROCK)
    r.box(10, 100, 40, 119, "Attor")
    r.plinth(90, w=5, h=4)


def build_hall(n):
    """An empty, walled, doored hall with a plinth: room for what comes
    next."""
    def _build(cv):
        r = Room(cv, n)
        r.plinth(4, w=5, h=4)
    return _build


ROOM_BUILDERS = [
    build_room_1, build_room_2, build_room_3, build_room_4,
    build_room_5, build_room_6,
] + [build_hall(n) for n in range(7, 17)]

# Doors: every pair of rooms side by side in the same row, except the
# two either side of room 6 ("the dark"), which has none.
DOORS = [
    (row, col)
    for row in range(GRID)
    for col in range(GRID - 1)
    if (row, col) not in ((1, 0), (1, 1))
]

# Shafts: enough vertical links to make the museum one connected path,
# with room 6 reaching the rest of it only through room 10 below,
# an empty hall with no light of its own.
SHAFTS = [
    (0, 0, 50),  # room 1 down to room 5
    (2, 0, 50),  # room 3 down to room 7
    (3, 1, 50),  # room 8 down to room 12
    (1, 1, 50),  # room 6 down to room 10
    (0, 2, 50),  # room 9 down to room 13
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


if __name__ == "__main__":
    run_cli(__doc__, OUT_PATH, paint, ENTRANCE_X0, ENTRANCE_X1)
