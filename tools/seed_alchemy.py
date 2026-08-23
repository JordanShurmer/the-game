#!/usr/bin/env python3
"""Paint the alchemy gallery: the poison, the water, and what the two make
of each other, and then the salts, the metals and the two magics that
came after, east of the physics gallery.

    tools/seed_alchemy.py           # draws data/rooms/alchemy_0.png
    tools/seed_alchemy.py --check   # holds the file on disk to the rules

Same shape as tools/seed_gallery.py, sharing tools/museum.py: sixteen
rooms in a four by four grid. Rooms 1 to 6 are the first alchemy and
rooms 7 to 14 are the second; room 10 and rooms 15 and 16 are empty
halls with a plinth, room for what comes next. See docs/alchemy.md,
"The alchemy gallery", for the room table this draws from.

Room 10 stays empty on purpose as much as rooms 15 and 16 do: it is
where room 6 comes down, and room 6 is judged by what can be seen from
it, so nothing in room 10 may make a light.

Room 6, "the dark", is sealed from its row neighbours on purpose: no
door to room 5 or room 7, so nothing either room lights can be seen
from it. It reaches the rest of the museum through a shaft down to
room 10 instead, an empty hall with no light of its own.

This tool draws fixed geometry from a table of room numbers; it uses
no randomness, so it draws the same file byte for byte every time it
runs.
"""

from museum import GRID, AIR, BEDROCK, Canvas, Room, door, shaft, run_cli

OUT_PATH = "data/rooms/alchemy_0.png"

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
    """The mix: a rack of alternating Attor and water pipettes along the
    ceiling, each dripping through a hole one cell wide into one wide
    basin. A row of drips makes a field of sparks the width of the
    room, where two streams meeting at a single point make one
    saturated blob of light.

    Each pipette is walled off from the one beside it, so the two
    liquids cannot settle by density into one heavy half and one light
    half before they drain. Every column keeps what it was drawn with,
    and the curtain stays alternating for as long as it falls.

    It runs for about as long as the deepest column: 6 by 62 cells is
    372 of them, and one hole one cell wide passes one a tick.
    """
    r = Room(cv, 2)
    ceiling_top, ceiling_bottom = 4, 70
    r.box(4, ceiling_top, 115, ceiling_bottom, BEDROCK)

    n = 0
    for lx in range(8, 108, 7):
        fill = "Attor" if n % 2 == 0 else "Water"
        n += 1
        r.box(lx, ceiling_top + 3, lx + 5, ceiling_bottom - 3, fill)
        hole = lx + 2
        r.box(hole, ceiling_bottom - 3, hole, ceiling_bottom, AIR)

    r.box(4, 90, 115, 119, BEDROCK)
    r.box(8, 94, 111, 119, AIR)
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
    """The rain, and the seal: water rains through a perforated ceiling
    onto a shallow pool of Attor. For the first hundred ticks the whole
    width of the pool sparks. Then it stops, and it never starts again.

    This room is the lesson the other two are built to answer, and it
    is left as it is on purpose. Water is lighter than Attor and floats
    on it, and the Smylt the two make is heavier than water and lighter
    than Attor, so it settles exactly between them. The pool caps
    itself with its own product wherever a drop lands. Nothing here is
    used up: the pool is still poison and the rain is still water, and
    they can no longer reach each other.

    Room 2 and room 6 answer it by never letting the two meet anywhere
    but in the air. See docs/alchemy.md, "Layering seals a slow drip".
    """
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
    """The dark: two chambers in the ceiling, one of Attor and one of
    water, each draining down a duct one cell wide. The two ducts come
    out side by side, so the two liquids fall as neighbouring columns
    for the whole depth of the room and react the whole way down. What
    the visitor sees is a ribbon of sparks hanging in a black room, and
    nothing else: this room has no door to either neighbour, and it
    reaches the museum by a shaft down to an unlit hall.

    Every other room learns the same lesson the hard way. A drip onto
    a pool seals its own front, because the Smylt it makes is denser
    than water and lighter than Attor and settles between the two
    exactly where the drop landed. See docs/alchemy.md, "Layering
    seals a slow drip". Nothing settles here, because the two never
    meet anywhere but in the air.

    A duct one cell wide passes one cell a tick, so a chamber of about
    1400 cells runs for about 1400 ticks a side.
    """
    r = Room(cv, 6)

    DUCT_A, DUCT_B = 58, 59
    top, bottom = 6, 44
    mouth = 56  # where both ducts open into the room

    r.box(18, 4, 99, mouth, BEDROCK)
    r.box(22, top, DUCT_A - 1, bottom, "Attor")
    r.box(DUCT_B + 1, top, 95, bottom, "Water")

    r.box(DUCT_A, bottom, DUCT_A, mouth, AIR)
    r.box(DUCT_B, bottom, DUCT_B, mouth, AIR)

    r.plinth(4, w=5, h=4)


# ------------------------------------------------- the second alchemy

def build_room_7(cv):
    """The salt road: salt into water on the left, and brine over lava on
    the right. The road runs both ways, and heat is what walks it back.

    The left basin holds 696 cells of water under 348 cells of room, and
    the hopper over it holds 252 cells of salt, so the pool that takes it
    up cannot brim over. Salt and water make two cells of brine out of two
    cells of themselves, so nothing grows on the way in either.

    The right pan is the lesson as well as the road. Brine dries on lava
    and the salt it leaves is heavier than brine and lighter than lava, so
    it settles exactly between them and caps the pan, the way Smylt caps a
    pool of Attor in room 4. The pan sparks nothing, dries a little, and
    then stands as a crust with brine still under it, for ever.
    """
    r = Room(cv, 7)
    r.tank(12, 6, 36, 26, "Sealt", hole_side="bottom", hole_lo=23, hole_hi=24)
    r.box(6, 84, 42, 119, BEDROCK)
    r.box(10, 84, 38, 119, AIR)
    r.box(10, 96, 38, 119, "Water")

    r.tank(76, 6, 112, 30, "Brine", hole_side="bottom", hole_lo=93, hole_hi=94)
    r.box(76, 84, 112, 119, BEDROCK)
    r.box(80, 84, 108, 119, AIR)
    r.box(80, 104, 108, 119, "Lava")


def build_room_8(cv):
    """Black powder, made rather than found. A reaction takes two cells and
    black powder is made of three things, so it is made in two steps: nitre
    and brimstone make the black salt where they touch, and the black salt
    takes up coal.

    Two tubs, one either side of the shaft down to room 12, so nothing
    falls down it. Each tub is banded nitre and brimstone four cells at a
    time, which puts every band against a band of the other: the black salt
    is made in the tub and drains out of it. Under each tap is a walled bed
    of coal, which is where the second step happens and where the powder
    stays.

    A tub holds 288 cells over a bed with 348 cells of room, so the beds
    hold everything both tubs can pass. Nothing here is lit. The powder is
    the exhibit; the fire is the visitor's to bring.
    """
    r = Room(cv, 8)
    for x0, x1, hole in ((8, 44, 24), (76, 112, 92)):
        r.box(x0, 6, x1, 34, BEDROCK)
        r.box(x0 + 3, 9, x1 - 3, 31, AIR)
        n = 0
        for ly in range(9, 30, 4):
            fill = "Nitre" if n % 2 == 0 else "Brimstone"
            n += 1
            r.box(x0 + 3, ly, x1 - 3, ly + 3, fill)
        r.box(hole, 31, hole + 1, 34, AIR)

        r.box(x0, 96, x1, 119, BEDROCK)
        r.box(x0 + 4, 96, x1 - 4, 119, AIR)
        r.box(x0 + 4, 108, x1 - 4, 119, "Coal")


def build_room_9(cv):
    """Lye, and the acid it answers. Ash left standing in water is lye, and
    lye and acid put each other out and leave the calm liquid room 2 makes
    a different way.

    Two hoppers over one basin: ash on the left, acid on the right. This
    room needs no trick to keep running, because nothing it makes can seal
    it. Smylt at 1.05 is lighter than lye at 1.1 and lighter than acid at
    1.2, so what the reaction leaves floats up out of the front instead of
    settling across it, and the acid still arriving sinks straight through
    the lye to what has not reacted yet.

    The basin is on the left of the room, clear of the shaft down to
    room 13.
    """
    r = Room(cv, 9)
    r.tank(6, 6, 26, 34, "Ash", hole_side="bottom", hole_lo=15, hole_hi=16)
    r.tank(28, 6, 48, 34, "Acid", hole_side="bottom", hole_lo=37, hole_hi=38)

    r.box(6, 76, 48, 119, BEDROCK)
    r.box(10, 76, 44, 119, AIR)
    r.box(10, 92, 44, 119, "Water")
    r.plinth(80, w=8, h=6)


def build_room_11(cv):
    """The quicksilver. A pan floored with gold, and a tank of quicksilver
    over it: the two make an amalgam along the line where they meet, and
    gold, which no other liquid in the world can move at all, goes into it.

    The pan holds 864 cells over the gold and the tank holds 612, so the
    quicksilver stands in the pan and never reaches the doors either side.
    """
    r = Room(cv, 11)
    r.box(20, 92, 99, 119, BEDROCK)
    r.box(24, 92, 95, 119, AIR)
    r.box(24, 104, 95, 119, "Gold")
    r.tank(40, 6, 80, 30, "Cwicseolfor", hole_side="bottom", hole_lo=58, hole_hi=60)


def build_room_12(cv):
    """The gleam, in the two halves it has.

    On the left a pipette of Galdor drips onto a block of plain rock. A
    spell is spent in the flash it makes, so what the visitor sees is a
    spark and a stone that has turned the colour of ice: rock with a spell
    in it.

    On the right a vein of that gleam, already made, stands under a pipette
    of water. A gleam is no light of its own. It answers water with one, a
    spark for every drop, and it is never used up doing it: the tap is what
    runs out, and until it does the vein flickers.

    Both taps are pipettes and not ponds, so both keep time: 6 by 64 cells
    is 384 of them, and a hole one cell wide passes one a tick. See
    docs/alchemy.md, "A tap is a pipette, not a pond". Both stand clear of
    the shaft mouth in the middle of the ceiling.

    The left block is skinned and not eaten. There is no row for Galdor on
    a gleam, so the first shell of gleam the spell makes is where it stops:
    the block ends the room rimmed in ice blue over plain grey, and the
    spell that is left stands on top of it with nothing to do.
    """
    r = Room(cv, 12)
    top, bottom = 6, 76
    for x0, fill in ((10, "Galdor"), (90, "Water")):
        r.box(x0, top, x0 + 11, bottom, BEDROCK)
        r.box(x0 + 3, top + 3, x0 + 8, bottom - 3, fill)
        r.box(x0 + 5, bottom - 3, x0 + 5, bottom, AIR)

    r.box(8, 104, 34, 119, "Rock")
    r.box(88, 104, 111, 119, "Leoma")


def build_room_13(cv):
    """The cure: two ducts a cell apart drop Attor and Haelu side by side
    down a dark room, and nothing happens that the eye can see.

    That is the exhibit. Room 6 next door drops Attor and water the same
    way and hangs a ribbon of sparks down the room; this pair leaves the
    same calm liquid and throws no light at all. The mix is loud and the
    cure is quiet, and the only way to show a quiet thing is beside a loud
    one.

    The two must meet in the air here for the same reason they must in
    room 6: Smylt at 1.05 settles between Haelu at 0.96 and Attor at 1.25,
    so a drip onto a pool caps its own front on the first drop. See
    docs/alchemy.md, "Layering seals a slow drip".
    """
    r = Room(cv, 13)

    DUCT_A, DUCT_B = 30, 31
    top, bottom = 8, 40
    mouth = 52

    r.box(8, 6, 52, mouth, BEDROCK)
    r.box(12, top, DUCT_A - 1, bottom, "Attor")
    r.box(DUCT_B + 1, top, 48, bottom, "Haelu")

    r.box(DUCT_A, bottom, DUCT_A, mouth, AIR)
    r.box(DUCT_B, bottom, DUCT_B, mouth, AIR)

    r.plinth(80, w=8, h=6)


def build_room_14(cv):
    """The shadow. A slab of the gleam under a tank of Sceadu: what the
    shadow lies on is blinded, gleam to dead black glass, from the top
    down. The shadow is not used up doing it.

    It goes no deeper than the shell it makes, the same way the spell in
    room 12 does: there is no row for Sceadu on obsidian, so 1152 cells of
    gleam under a whole tank of shadow give up 58 and then stand.

    It puts fires out as well, and this room cannot show that, because
    nothing in the museum is alight. The blinding is the half of it a
    still picture can carry.
    """
    r = Room(cv, 14)
    r.box(20, 90, 99, 119, BEDROCK)
    r.box(24, 90, 95, 119, AIR)
    r.box(24, 104, 95, 119, "Leoma")
    r.tank(34, 6, 86, 34, "Sceadu", hole_side="bottom", hole_lo=58, hole_hi=60)


def build_hall(n):
    """An empty, walled, doored hall with a plinth: room for what comes
    next. The plinth sits clear of every wall, so it reads as a
    standalone pedestal and not a bump on the corner."""
    def _build(cv):
        r = Room(cv, n)
        r.plinth(56, w=8, h=6)
    return _build


ROOM_BUILDERS = [
    build_room_1, build_room_2, build_room_3, build_room_4,
    build_room_5, build_room_6, build_room_7, build_room_8,
    build_room_9, build_hall(10), build_room_11, build_room_12,
    build_room_13, build_room_14,
] + [build_hall(n) for n in range(15, 17)]

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
    (1, 1, 102),  # room 6 down to room 10, clear of its centred basin
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
