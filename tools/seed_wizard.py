#!/usr/bin/env python3
"""Draw the player sprite sheet: a wizard in ink, on nothing.

    tools/seed_wizard.py            # draws data/sprites/wizard.png
    tools/seed_wizard.py --check    # holds the file on disk to the rules
    tools/seed_wizard.py --seed 7   # another hand draws it

The sheet is authored data, the same way the tile sets are. This tool
draws a first one and redraws it when the wizard changes. A single
frame belongs in a pixel editor; six animations do not, which is why
there is a tool.

WHAT IT DRAWS

The wizard of the reference drawing: a squat figure under a tall hat
whose tip flops over, a beard to his knees, a robe to the ground, two
small feet below it, and a staff with a round head that crosses his
body and rises past his hat. He is drawn in one ink, in three blues and
a pale beard, because the reference is one pen on paper.

He is built from parts, not from a picture. Every frame calls the same
draw with a different set of numbers: how far he leans, how high he
rides, where each foot is, how the hem swings, where the hat tip
trails. That is what makes six animations of one wizard instead of six
wizards.

THE RULES IT MUST NOT BREAK

  - Every frame faces right. The game mirrors the frame to face left,
    so a frame that is not symmetrical about what it means to face is
    two different wizards.
  - The body box is where the wizard collides, and the game reads it
    from the constants below, not from the picture. Art may leave the
    box (a hat and a staff must not catch on a ceiling) but the feet
    must stand on the bottom of it, or he floats.
  - A frame that a row declares must hold ink. An empty frame is a hole
    in an animation and reads as the wizard blinking out.

--check reads the PNG back and holds it to all three.
"""

import argparse
import math
import os
import random
import struct
import sys
import zlib

OUT_PATH = "data/sprites/wizard.png"

# One frame, and the grid the sheet lays them out in. A row is an
# animation and a column is a frame of it, so the file reads as a
# contact sheet in any image viewer.
#
# A frame is taller than it is wide, and taller than the wizard. The
# room above him is for the head of the staff, which he holds high; the
# room below him is for the jetpack flame, which comes out under the
# robe. Both belong to the frame, so the game draws one picture and
# never has to know where a flame goes.
FRAME_W = 24
FRAME_H = 32
COLUMNS = 6
ROWS = 6

# Where the wizard collides. src/player.odin holds the same four
# numbers, and src/sprite.odin has a test that the art respects them.
#
# The height is what the world allows, not what the drawing wants. Two
# tiles that meet share the cells within WANG_SEAM of the border, so
# every mouth in the world narrows to the same channel where it crosses
# a seam. That channel is 16 cells in the shipped sets. A body taller
# than that cannot leave the tile it is in, whatever the cave looks like
# in the middle, so the body is 13 and keeps a cell of air either side.
# src/player.odin holds a test that measures the channel and fails if a
# reseeded set ever closes it.
BODY_X = 8  # left column of the body box inside a frame
BODY_W = 8
BODY_Y = 11  # top row of the body box inside a frame
BODY_H = 13

FOOT_Y = BODY_Y + BODY_H - 1  # the row his feet stand on: 23

# How far the art may lift off the bottom of the body box. A walk rides
# up and down and a flame lifts him off his feet, so the gate allows a
# little; a wizard drawn any higher than this is floating.
FOOT_SLACK = 2

# A row of the sheet, and how many of its columns hold a frame. The
# rest of the row is left transparent on purpose; src/sprite.odin reads
# the same table and never asks for a frame that is not there.
ROW_NAMES = ["idle", "walk", "run", "rise", "fall", "jet"]
ROW_FRAMES = {"idle": 4, "walk": 6, "run": 6, "rise": 2, "fall": 2, "jet": 4}

CLEAR = (0, 0, 0, 0)

# One pen, three pressures, and the paper the beard is drawn on. The
# world is browns and greys, so a blue wizard is never lost in it.
INK_DEEP = (22, 30, 78, 255)
INK = (40, 58, 138, 255)
INK_PALE = (84, 116, 205, 255)
BEARD = (223, 227, 240, 255)
BEARD_SHADE = (160, 173, 210, 255)
ORB = (255, 208, 122, 255)
ORB_CORE = (255, 251, 233, 255)

# The jetpack plume. The game already burns at this color, so a player
# reads the flame as fire before he is told what it is.
FLAME_HOT = (255, 214, 96, 255)
FLAME = (255, 138, 32, 255)


# ------------------------------------------------------------ the drawing kit


def blank_frame():
    return [[CLEAR] * FRAME_W for _ in range(FRAME_H)]


def put(f, x, y, color):
    x, y = int(round(x)), int(round(y))
    if 0 <= x < FRAME_W and 0 <= y < FRAME_H:
        f[y][x] = color


def disc(f, cx, cy, r, color):
    for y in range(int(cy - r), int(cy + r) + 1):
        for x in range(int(cx - r), int(cx + r) + 1):
            if (x - cx) ** 2 + (y - cy) ** 2 <= r * r:
                put(f, x, y, color)


def rect(f, x0, y0, x1, y1, color):
    for y in range(int(y0), int(y1) + 1):
        for x in range(int(x0), int(x1) + 1):
            put(f, x, y, color)


def thick_line(f, x0, y0, x1, y1, r, color):
    """A stroke of the pen from one point to another."""
    steps = int(max(abs(x1 - x0), abs(y1 - y0)) * 2) + 1
    for i in range(steps + 1):
        t = i / steps
        disc(f, x0 + (x1 - x0) * t, y0 + (y1 - y0) * t, r, color)


def taper(f, x0, y0, half0, x1, y1, half1, color):
    """A body that changes width along its length.

    A robe, a beard, a sleeve and a hat are all one of these, which is
    what lets the wizard lean and sway without a second drawing of him.
    It runs in either direction, because a hat is drawn up from the brim
    and a robe is drawn down from the shoulders.
    """
    span = max(1, int(round(abs(y1 - y0))))
    for i in range(span + 1):
        t = i / span
        cx = x0 + (x1 - x0) * t
        half = half0 + (half1 - half0) * t
        y = y0 + (y1 - y0) * t
        for x in range(int(round(cx - half)), int(round(cx + half)) + 1):
            put(f, x, y, color)


def edge_left(f, body, edge):
    """Darken the first column of every run of one color.

    The pen presses hardest where a fold turns away from the light. One
    column of that is enough to stop a shape reading as a cut-out, and
    it costs nothing to place because the shape is already down.
    """
    for y in range(FRAME_H):
        run = False
        for x in range(FRAME_W):
            here = f[y][x] == body
            if here and not run:
                f[y][x] = edge
            run = here


# -------------------------------------------------------------- the wizard


def draw_wizard(f, p):
    """One frame of the wizard, from the numbers that make it that frame.

    The parts go down in the order a pen would: what is behind first.
    The drawing is read from the bottom up, because his feet stand on a
    floor and everything else is measured from there.
    """
    ground = FOOT_Y + p["bob"]
    centre = BODY_X + BODY_W / 2 - 0.5  # 11.5, the middle of the body box
    upper = centre + p["lean"]

    hem_y = ground - 2
    shoulder_y = ground - 11 + p["squash"]
    brim_y = shoulder_y - 1
    tip_x = upper + p["tip"][0]
    tip_y = brim_y - 7 + p["tip"][1]

    # The flame comes first: it is behind him and below him.
    if p["jet"] > 0:
        plume(f, centre + p["hem_sway"], ground, p["flicker"])

    # The feet, first, so the robe falls over the top of them. They are
    # all that ever shows of his legs, the same way they are in the
    # drawing.
    for dx, dy in (p["foot_back"], p["foot_front"]):
        rect(f, centre + dx - 1, ground - 1 + dy, centre + dx + 1, ground + dy, INK_DEEP)

    # The robe, shoulders to hem. It is the mass of him and it is dark,
    # with one fold catching the light down the right. It stops short of
    # his feet, or the feet are inside it and he has none.
    hem_x = centre + p["hem_sway"]
    taper(f, upper, shoulder_y, 3.3, hem_x, hem_y, p["hem"], INK_DEEP)
    taper(f, upper + 1.7, shoulder_y + 2, 1.0, hem_x + 2.4, hem_y - 1, 1.4, INK)

    # The sleeve that reaches out to the staff.
    hand_x = upper + p["hand"][0]
    hand_y = shoulder_y + p["hand"][1]
    thick_line(f, upper + 1.3, shoulder_y + 2, hand_x, hand_y, 1.0, INK)

    # The beard: the one pale thing on him, and the thing that says
    # wizard. It is a narrow wedge that comes to a point above the hem,
    # not a panel: the robe has to show dark on both sides of it, or he
    # reads as a lamp with a window in it.
    beard_x = upper + p["beard"]
    beard_end = hem_y - 2
    taper(f, upper, brim_y + 2, 1.9, beard_x, beard_end, 0.5, BEARD)

    # One strand down it. A flat wedge of one color reads as cloth; a
    # line along the way the hair falls reads as hair.
    thick_line(f, upper - 0.7, brim_y + 3, beard_x - 0.3, beard_end - 1, 0.3, BEARD_SHADE)

    # The hat. The cone is drawn up from the brim, and the brim over the
    # foot of it, which is the order the shapes overlap in the drawing.
    taper(f, upper - 0.3, brim_y, 3.2, tip_x, tip_y, 0.7, INK_DEEP)
    taper(f, upper + 0.5, brim_y - 1, 1.6, tip_x + 0.3, tip_y + 1.3, 0.4, INK)
    thick_line(f, tip_x, tip_y, tip_x + p["flop"][0], tip_y + p["flop"][1], 0.8, INK_DEEP)

    brim(f, upper, brim_y, p["brim"])

    # The staff crosses him and rises past his hat, as it does in the
    # drawing, so it is drawn last and lies over everything.
    foot_dx, foot_dy = p["staff_foot"]
    head_dx, head_dy = p["staff_head"]
    head_x = upper + head_dx
    head_y = shoulder_y + head_dy
    thick_line(f, centre + foot_dx, ground + foot_dy, head_x, head_y, 0.6, INK_DEEP)

    disc(f, hand_x, hand_y, 1.0, INK)
    disc(f, head_x, head_y, 2.1, ORB)
    disc(f, head_x - 0.6, head_y - 0.6, 0.9, ORB_CORE)

    edge_left(f, INK, INK_PALE)
    edge_left(f, BEARD, BEARD_SHADE)


def brim(f, cx, y, half):
    """The wide flat brim the whole hat hangs from.

    It is three rows and no more. The drawing gives it almost no
    thickness and all of its width, and that is what makes the hat read
    as a hat at this size rather than as a cone on a head.
    """
    rect(f, cx - half + 1.0, y - 1, cx + half - 1.0, y - 1, INK)
    rect(f, cx - half, y, cx + half, y, INK_DEEP)
    rect(f, cx - half + 0.8, y + 1, cx + half - 0.8, y + 1, INK_DEEP)


def plume(f, cx, ground, flicker):
    """The jetpack, which is a flame under the robe and nothing else.

    He wears no machine. The drawing gave him no pack, so the lift comes
    out from under the robe, which is the read a wizard wants anyway.
    """
    length = 6 + flicker * 1.5
    for i in range(int(round(length))):
        t = i / length
        half = 1.8 * (1.0 - t) + 0.3
        row = ground + 1 + i
        for x in range(int(round(cx - half)), int(round(cx + half)) + 1):
            put(f, x, row, FLAME_HOT if t < 0.4 else FLAME)


# ------------------------------------------------------------ the animations


def base_params():
    """A wizard standing still, which every other frame is a change to."""
    return {
        "bob": 0.0,  # the whole of him, up and down
        "lean": 0.0,  # everything above the hem, left and right
        "squash": 0.0,  # his shoulders, up and down
        "hem": 5.0,  # half the width of the robe where it ends
        "hem_sway": 0.0,
        "beard": 0.0,  # where the point of the beard swings to
        "brim": 5.4,  # half the width of the hat
        "tip": (-2.1, 0.0),  # where the point of the hat leans
        "flop": (-1.4, 1.1),  # and where it flops over to
        "hand": (3.5, 2.5),  # the grip, from his shoulder
        "staff_foot": (2.2, 0.0),  # the foot of the staff, from his feet
        "staff_head": (6.0, -7.0),  # the head of it, from his shoulder
        "foot_back": (-1.9, 0.0),
        "foot_front": (1.6, 0.0),
        "jet": 0.0,
        "flicker": 0.0,
    }


def frames_of(row):
    """The numbers for every frame of one animation."""
    out = []
    count = ROW_FRAMES[row]

    for i in range(count):
        p = base_params()
        phase = 2 * math.pi * i / count

        if row == "idle":
            # He breathes and the hat tip settles. Nothing else moves,
            # or standing still reads as fidgeting.
            p["bob"] = -0.5 + 0.5 * math.cos(phase)
            p["squash"] = 0.3 * math.sin(phase)
            p["beard"] = 0.25 * math.sin(phase)
            p["tip"] = (-2.1 + 0.3 * math.sin(phase), 0.25 * math.cos(phase))
            p["hem_sway"] = 0.2 * math.sin(phase)

        elif row == "walk":
            # The robe hides his legs, so the walk is in the feet, the
            # hem, and the rise and fall of the whole of him.
            stride = 2.1 * math.sin(phase)
            p["bob"] = -abs(math.sin(phase)) * 0.9
            p["lean"] = 0.3
            p["foot_back"] = (-1.4 - stride, -max(0.0, -stride) * 0.7)
            p["foot_front"] = (1.4 + stride, -max(0.0, stride) * 0.7)
            p["hem_sway"] = -0.6 * math.sin(phase)
            p["hem"] = 5.0 + 0.25 * abs(math.cos(phase))
            p["beard"] = -0.45 * math.sin(phase)
            p["tip"] = (-2.1 - 0.4 * math.sin(phase), 0.0)
            p["staff_foot"] = (2.2 + 0.5 * math.sin(phase), 0.0)

        elif row == "run":
            # The same walk, leaning into it, with everything trailing.
            stride = 3.1 * math.sin(phase)
            p["bob"] = -abs(math.sin(phase)) * 1.4
            p["lean"] = 0.7
            p["squash"] = 0.4
            p["foot_back"] = (-1.4 - stride, -max(0.0, -stride) * 1.1)
            p["foot_front"] = (1.4 + stride, -max(0.0, stride) * 1.1)
            p["hem_sway"] = -0.9 - 0.5 * math.sin(phase)
            p["hem"] = 5.2
            p["beard"] = -1.1 - 0.4 * math.sin(phase)
            p["brim"] = 5.2
            p["tip"] = (-2.9, 0.6)
            p["flop"] = (-1.6, 0.6)
            p["staff_foot"] = (1.6, 0.0)

        elif row == "rise":
            # Going up: everything he wears is pulled down after him.
            p["bob"] = -0.4 * i
            p["squash"] = -0.5
            p["hem"] = 3.4 - 0.2 * i
            p["beard"] = 0.0
            p["foot_back"] = (-1.6, -1.0 - 0.25 * i)
            p["foot_front"] = (1.6, -1.4 - 0.25 * i)
            p["tip"] = (-1.4, 1.0 + 0.3 * i)
            p["flop"] = (-0.9, 1.4)
            p["hand"] = (3.1, 1.3)

        elif row == "fall":
            # Going down: everything is pulled up, and his feet spread.
            p["bob"] = -0.2 * i
            p["squash"] = 0.4
            p["hem"] = 4.6 + 0.25 * i
            p["hem_sway"] = 0.0
            p["beard"] = 0.0
            p["foot_back"] = (-2.2, 0.0)
            p["foot_front"] = (2.1, 0.0)
            p["tip"] = (-2.1, -1.0 - 0.25 * i)
            p["flop"] = (-1.5, -0.9)
            p["hand"] = (3.2, 2.6)

        elif row == "jet":
            # Under thrust: the robe is blown out, the staff comes down,
            # and the flame beats.
            beat = math.sin(phase)
            p["bob"] = -0.6 - 0.25 * beat
            p["squash"] = -0.25
            p["hem"] = 4.7 + 0.5 * beat
            p["hem_sway"] = 0.25 * beat
            p["beard"] = -0.5
            p["foot_back"] = (-1.6, -1.2)
            p["foot_front"] = (1.6, -1.5)
            p["tip"] = (-2.2, 1.1)
            p["flop"] = (-1.4, 1.2)
            p["hand"] = (3.3, 3.1)
            p["staff_foot"] = (2.6, -1.2)
            p["staff_head"] = (5.4, -5.5)
            p["jet"] = 1.0
            p["flicker"] = beat

        out.append(p)
    return out


def draw_sheet():
    sheet = [[CLEAR] * (FRAME_W * COLUMNS) for _ in range(FRAME_H * ROWS)]

    for row_index, row in enumerate(ROW_NAMES):
        for column, p in enumerate(frames_of(row)):
            f = blank_frame()
            draw_wizard(f, p)
            for y in range(FRAME_H):
                for x in range(FRAME_W):
                    if f[y][x] != CLEAR:
                        sheet[row_index * FRAME_H + y][column * FRAME_W + x] = f[y][x]

    return sheet


# ------------------------------------------------------------------- the PNG


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
    """Read the sheet back, whatever wrote it and whatever filters it used."""
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
    return rows


# ----------------------------------------------------------------- the gate


def check(path):
    """Hold the file on disk to the three rules in the header."""
    faults = []
    if not os.path.exists(path):
        return [f"{path} does not exist; run this tool with no arguments"]

    sheet = read_png(path)
    if len(sheet) != FRAME_H * ROWS or len(sheet[0]) != FRAME_W * COLUMNS:
        return [
            f"{path} is {len(sheet[0])}x{len(sheet)}, "
            f"and the sheet must be {FRAME_W * COLUMNS}x{FRAME_H * ROWS}"
        ]

    for row_index, row in enumerate(ROW_NAMES):
        for column in range(COLUMNS):
            ink = 0
            lowest = -1
            for y in range(FRAME_H):
                for x in range(FRAME_W):
                    pixel = sheet[row_index * FRAME_H + y][column * FRAME_W + x]
                    if pixel[3] == 0:
                        continue
                    ink += 1
                    # The flame reaches past his feet and holds nothing
                    # up, so it says nothing about where he stands.
                    if pixel not in (FLAME, FLAME_HOT):
                        lowest = max(lowest, y)

            declared = column < ROW_FRAMES[row]
            if declared and ink == 0:
                faults.append(f"{row} frame {column} is empty, and the row declares it")
            if not declared and ink != 0:
                faults.append(f"{row} frame {column} holds ink, and the row does not declare it")
            if declared and not FOOT_Y - FOOT_SLACK <= lowest <= FOOT_Y:
                faults.append(
                    f"{row} frame {column} ends at row {lowest}, and the wizard stands on "
                    f"row {FOOT_Y}, within {FOOT_SLACK} above it and never below"
                )
    return faults


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="hold the file on disk to the rules")
    parser.add_argument("--seed", type=int, default=0x1A2D, help="another hand draws it")
    parser.add_argument("--out", default=OUT_PATH)
    args = parser.parse_args()

    if args.check:
        faults = check(args.out)
        for fault in faults:
            print(fault, file=sys.stderr)
        if faults:
            sys.exit(1)
        print(f"{args.out}: {sum(ROW_FRAMES.values())} frames, and every rule holds")
        return

    # The seed exists so a second hand can be asked for, later, without
    # this tool changing shape. Nothing below reads randomness yet --
    # every number is authored -- so today every seed draws the same
    # wizard.
    random.Random(args.seed)
    write_png(args.out, draw_sheet())
    print(f"{args.out}: {FRAME_W * COLUMNS}x{FRAME_H * ROWS}, {sum(ROW_FRAMES.values())} frames")


if __name__ == "__main__":
    main()
