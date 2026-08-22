#!/usr/bin/env python3
"""Paint the gallery: sixteen hand made rooms, one per thing the sandbox does.

    tools/seed_gallery.py           # draws data/rooms/gallery.png
    tools/seed_gallery.py --check   # holds the file on disk to the rules

The gallery is one biome region, `generator = image`. Its picture is
512x512, one pixel to one world cell, in material colors, read from
data/materials.txt. See docs/physics.md, "The gallery", for the room
table this draws from and the numbers this file must hold to.

The canvas, the room, the doors, the shafts, the PNG reader and writer,
and the three rules `--check` holds are all in tools/museum.py, shared
with every other gallery. This file holds only the room table.

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

This tool draws fixed geometry from a table of room numbers; it does
not need a layout engine. It uses no randomness, so it draws the same
file byte for byte every time it runs.
"""

from museum import GRID, INTERIOR, AIR, BEDROCK, Canvas, Room, door, shaft, run_cli

OUT_PATH = "data/rooms/gallery.png"

# The entrance shaft, in the top edge of the whole image. It has to
# reach at least 12 cells straight down from row 0: 4 to clear room
# 1's own north wall and 8 more into the open room behind it.
# world_find_mouth (src/player.odin) starts its search at world x 0
# and grows outward, so a shaft here is the mouth it is most likely to
# land beside.
ENTRANCE_X0, ENTRANCE_X1 = 4, 24   # [x0, x1)
ENTRANCE_DEPTH = 12


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

    # Three taps, a funnel, and one narrow column.
    #
    # A wide tank shows nothing. Each liquid lands under its own chute,
    # spreads only as far as it has to, and settles as three puddles
    # side by side that never meet. Bringing them into one tank is not
    # enough either: the step swaps a heavy cell with a lighter one
    # below it, and never with one beside it, so a wide tank settles
    # with no cell resting on anything lighter and still reads as a
    # diagonal smear rather than as layers. The column is 13 cells
    # across, which is too narrow for a diagonal to fit in, so the only
    # arrangement left is the right one.
    # The funnel and the column go down first. A chute drawn before
    # them is painted over by their walls, and every tap is then sealed
    # by a room that still looks right in a picture of it at rest.
    r.box(34, 28, 86, 68, BEDROCK)
    r.box(38, 32, 82, 62, AIR)

    # The funnel floor slopes. A flat one does not funnel: a liquid
    # spreads sideways only where the ground falls away beside it or
    # more liquid presses from above, so a pool sitting on a flat floor
    # beside a hole has no reason to move towards it and simply stays
    # at the side of the room. A slope gives it the reason.
    for lx in range(38, 56):
        r.box(lx, 40 + (lx - 38) * 22 // 18, lx, 67, BEDROCK)
    for lx in range(65, 83):
        r.box(lx, 40 + (82 - lx) * 22 // 18, lx, 67, BEDROCK)

    r.box(50, 66, 70, 119, BEDROCK)
    r.box(54, 70, 66, 119, AIR)
    r.box(56, 62, 64, 70, AIR)      # the throat, down into the column

    for lx0, fill in ((38, "Oil"), (53, "Water"), (68, "Toxic_Sludge")):
        r.tank(lx0, 4, lx0 + 13, 25, fill, wall=2, hole_side="bottom",
               hole_lo=lx0 + 5, hole_hi=lx0 + 8)
        r.box(lx0 + 5, 26, lx0 + 8, 31, AIR)  # the chute into the funnel

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
    # The pillar stands 24 cells, not the whole height of the room. A
    # pillar taller than the tnt shadows the field completely, and a
    # field that is wholly in shadow shows nothing: the room reads as a
    # blast that did not go off. Rays that graze the top of this one
    # reach the upper face of the field, so the shadow lands as a
    # diagonal across it and the lit rock beside it is gone.
    r.box(50, 96, 57, 119, BEDROCK)
    r.box(66, 60, 92, 119, "Rock")
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


if __name__ == "__main__":
    run_cli(__doc__, OUT_PATH, paint, ENTRANCE_X0, ENTRANCE_X1)
