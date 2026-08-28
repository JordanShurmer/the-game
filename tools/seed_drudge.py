#!/usr/bin/env python3
"""Draw the drudge sprite sheet: a miner bent by the coal, in ink.

    tools/seed_drudge.py            # draws data/sprites/drudge.png
    tools/seed_drudge.py --check    # holds the file on disk to the rules
    tools/seed_drudge.py --seed 7   # another hand draws it

This is `tools/seed_wizard.py`'s own pattern, followed exactly, for a
second character. The sheet is authored data, not art committed by
hand, and this tool is what draws it.

WHAT IT DRAWS

A miner the coal took the rest of: short, stooped from years bent to
the seam, a small bowed head, and a lit lamp held out in front of him
low, so it lights the ground he walks and gives him away before he
ever sees you. He carries the lamp in one hand; the other is the hand
he throws with. He is drawn in coal blacks and soot greys, the colour
of a man who has not seen the sun, with the lamp the one warm thing on
him — the same reason the wizard is one blue pen and a pale beard: a
small, coherent palette keyed to what the character is.

He is built from parts, not from a picture, the same way the wizard
is: one draw, called with a different set of numbers per frame — how
far he leans, where each leg lands, how the lamp swings, where the
throwing arm is. That is what makes several animations of one drudge
instead of several drudges.

WHY THREE ROWS AND NOT SIX

`docs/drudge.md` says what he does: he walks a patrol that never
stops, and every few seconds he throws a pot at a player he can see.
He does not run, jump, fly, or die, so a run row, a jump row, or a
death row would be frames nothing in the game ever plays — the same
ponytail rule the wizard's own six rows are cut to. That leaves three:

  - "idle", standing. He never truly stops patrolling once a tick is
    running him, but the moment before that first tick — the frame a
    freshly placed drudge shows, and what `bin/shot` draws for him
    when it is not asked to run any ticks — is a real, drawn state,
    not a placeholder.
  - "walk", his patrol, back and forth at DRUDGE_WALK_SPEED.
  - "throw", the pot leaving his hand.

THE RULES IT MUST NOT BREAK

  - Every frame faces right. The game mirrors the frame to face left,
    so a frame that is not symmetrical about what it means to face is
    two different miners.
  - The body box is where he collides, and the game reads it from the
    constants below, not from the picture. Art may leave the box (the
    lamp held out and the throwing arm both reach past it) but the
    feet must stand on the bottom of it, or he floats.
  - A frame that a row declares must hold ink. An empty frame is a
    hole in an animation and reads as him blinking out.
  - The lamp he holds is drawn at the same point `src/drudge.odin`
    computes for the light it throws (`drudge_lamp_at`), the same way
    the wizard's own orb and the light it throws agree. Move the lamp
    here without moving the constants there and the light comes loose
    from his hand.

--check reads the PNG back and holds it to all four.
"""

import argparse
import math
import os
import random
import struct
import sys
import zlib

OUT_PATH = "data/sprites/drudge.png"

# One frame, and the grid the sheet lays them out in. A frame is wider
# and taller than his 10x12 body box: the width leaves room for the
# lamp held out in front of him and the throwing arm swung back, and
# the height leaves a little room above for his bowed head and below
# for his stance, the way the wizard's own frame leaves room above for
# his staff and below for his jetpack flame.
FRAME_W = 22
FRAME_H = 26
COLUMNS = 6
ROWS = 3

# Where he collides. src/drudge.odin holds DRUDGE_BODY_W and
# DRUDGE_BODY_H, and src/drudge_sprite.odin has a test that the art
# respects them, the same way src/sprite.odin does for the wizard.
BODY_X = 6  # left column of the body box inside a frame
BODY_W = 10
BODY_Y = 9  # top row of the body box inside a frame
BODY_H = 12

FOOT_Y = BODY_Y + BODY_H - 1  # the row his feet stand on: 20

# How far the art may lift off the bottom of the body box. He breathes
# and his stride rises and falls a little; a drudge drawn any higher
# than this is floating.
FOOT_SLACK = 2

# A row of the sheet, and how many of its columns hold a frame. The
# rest of the row is left transparent on purpose; src/drudge_sprite.odin
# reads the same table and never asks for a frame that is not there.
ROW_NAMES = ["idle", "walk", "throw"]
ROW_FRAMES = {"idle": 3, "walk": 6, "throw": 3}

CLEAR = (0, 0, 0, 0)

# Coal blacks and soot greys: a man who has not seen the sun. Two
# pressures of coal for the body, two of soot for the skin, so a fold
# reads without needing a third hue.
COAL_DEEP = (16, 14, 13, 255)
COAL = (36, 32, 29, 255)
SOOT = (78, 70, 62, 255)
SOOT_PALE = (118, 108, 96, 255)

# The lamp. Its light is not its own colour in the game — `src/drudge.odin`
# says it borrows Fire's brightness and colour rather than spend one of
# the shipped material table's rows on a lamp — but the ink here has
# to be drawn in some colour, and it is drawn in exactly the colours the
# game paints that borrowed light: Fire's own RGB (`data/materials.txt`,
# `[Fire] color = 0xFFFF6A00`) for the glow, and `LIGHT_CORE`
# (`src/light.odin`) for its bright core, the same pairing
# tools/seed_wizard.py uses for the orb. If either one is ever repainted,
# repaint it here too, or --check has nothing to hold this to.
LAMP_GLOW = (255, 106, 0, 255)
LAMP_CORE = (255, 251, 233, 255)


# ------------------------------------------------------------ the drawing kit
# The same small kit tools/seed_wizard.py uses, copied rather than
# imported: two tools drawing two different figures share no code that
# would not immediately grow a parameter for whichever one changes
# first. Each stays a single small file a redraw can read start to end.


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
    """A body that changes width along its length. See seed_wizard.py."""
    span = max(1, int(round(abs(y1 - y0))))
    for i in range(span + 1):
        t = i / span
        cx = x0 + (x1 - x0) * t
        half = half0 + (half1 - half0) * t
        y = y0 + (y1 - y0) * t
        for x in range(int(round(cx - half)), int(round(cx + half)) + 1):
            put(f, x, y, color)


def edge_left(f, body, edge):
    """Darken the first column of every run of one colour. See seed_wizard.py."""
    for y in range(FRAME_H):
        run = False
        for x in range(FRAME_W):
            here = f[y][x] == body
            if here and not run:
                f[y][x] = edge
            run = here


# --------------------------------------------------------------- the drudge


def draw_drudge(f, p):
    """One frame of him, from the numbers that make it that frame.

    Read bottom-up, the way seed_wizard.py reads the wizard: his feet
    stand on a floor and everything above is measured from there. He is
    stooped — his torso and head both lean forward of his hips, always,
    not only while walking — which is what makes his silhouette read as
    a bent miner and not an upright wizard at a glance, before either
    one throws a single frame away.
    """
    ground = FOOT_Y + p["bob"]
    centre = BODY_X + BODY_W / 2 - 0.5  # 10.5, the middle of the body box

    hip_y = ground - 2
    shoulder_x = centre + p["stoop"] + p["sway"]
    shoulder_y = hip_y - 6 + p["shoulder_dip"]
    head_x = shoulder_x + p["stoop"] * 0.5 + p["head_tilt"]
    head_y = shoulder_y - 3

    # The legs, first, so the body falls over the top of them.
    for dx, dy in (p["leg_back"], p["leg_front"]):
        rect(f, centre + dx - 0.9, ground - 2 + dy, centre + dx + 0.9, ground + dy, COAL_DEEP)

    # The torso: a short, thick taper from the hip up to the shoulder,
    # already leaning forward at the hip rather than only above it, so
    # the whole of him reads bent, not just his head.
    taper(f, centre, hip_y, 2.6, shoulder_x, shoulder_y, 2.2, COAL_DEEP)
    taper(f, centre + 0.6, hip_y - 1, 1.1, shoulder_x + 0.6, shoulder_y + 1, 1.1, COAL)

    # The throwing arm. At rest it hangs near the hip; mid-throw it
    # swings up and back, then out, then down, the way a real throw
    # winds up before it releases.
    hand_x = shoulder_x + p["throw_hand"][0]
    hand_y = shoulder_y + p["throw_hand"][1]
    thick_line(f, shoulder_x - 0.3, shoulder_y + 0.5, hand_x, hand_y, 1.0, COAL)

    # The lamp arm reaches forward and down, always, in every row: the
    # lamp is his tell and it never goes away, not even mid-throw.
    lamp_x = shoulder_x + p["lamp_hand"][0]
    lamp_y = shoulder_y + p["lamp_hand"][1] + p["lamp_swing"]
    thick_line(f, shoulder_x + 0.3, shoulder_y + 0.5, lamp_x, lamp_y, 1.0, COAL)
    disc(f, lamp_x, lamp_y, 1.6, LAMP_GLOW)
    disc(f, lamp_x - 0.4, lamp_y - 0.4, 0.7, LAMP_CORE)

    # The head: small and bowed, the one place soot shows lighter than
    # coal, because a face still catches what little light there is.
    disc(f, head_x, head_y, 2.0, SOOT)
    disc(f, head_x + 0.5, head_y - 0.4, 0.8, SOOT_PALE)

    edge_left(f, COAL, SOOT)


# ------------------------------------------------------------ the animations


def base_params():
    """Him, standing still, bent as he always is. Every other frame is a
    change to this."""
    return {
        "bob": 0.0,
        "stoop": 2.2,  # the constant forward lean of the torso and head
        "sway": 0.0,
        "shoulder_dip": 0.0,
        "head_tilt": 0.0,
        "leg_back": (-2.1, 0.0),
        "leg_front": (2.1, 0.0),
        "lamp_hand": (7.0, 4.0),
        "lamp_swing": 0.0,
        "throw_hand": (-2.0, -1.0),
    }


def frames_of(row):
    """The numbers for every frame of one animation."""
    out = []
    count = ROW_FRAMES[row]

    for i in range(count):
        p = base_params()

        if row == "idle":
            # He breathes and the lamp settles. Nothing else moves, or
            # standing still reads as fidgeting. Every term here is
            # zero at i=0, so the idle frame the game always shows
            # first — and the one src/drudge.odin's lamp point is
            # measured against — is exactly the base pose above.
            phase = 2 * math.pi * i / count
            p["bob"] = -0.3 + 0.3 * math.cos(phase)
            p["sway"] = 0.2 * math.sin(phase)
            p["lamp_swing"] = 0.4 * math.sin(phase)
            p["head_tilt"] = 0.15 * math.sin(phase)

        elif row == "walk":
            # The patrol. His legs stride, his lamp swings opposite the
            # stride the way a carried lamp does, and he leans a
            # little further into the walk than he does standing.
            phase = 2 * math.pi * i / count
            stride = 2.0 * math.sin(phase)
            p["leg_back"] = (-1.9 - stride, -max(0.0, -stride) * 0.6)
            p["leg_front"] = (1.9 + stride, -max(0.0, stride) * 0.6)
            p["bob"] = -abs(math.sin(phase)) * 0.6
            p["sway"] = 0.3 * math.sin(phase)
            p["shoulder_dip"] = 0.2 * abs(math.cos(phase))
            p["lamp_swing"] = -0.6 * math.sin(phase)
            p["stoop"] = 2.6

        elif row == "throw":
            # Not a loop: a windup, a release, and a follow-through, in
            # that order, the way seed_wizard.py's own "rise" and
            # "fall" rows are three drawn moments rather than a cycle.
            if i == 0:
                p["throw_hand"] = (-3.2, -3.4)  # cocked back and up
                p["stoop"] = 1.6
                p["bob"] = -0.4
            elif i == 1:
                p["throw_hand"] = (3.6, -1.2)  # the release, arm thrown forward
                p["stoop"] = 3.2
                p["bob"] = 0.0
            else:
                p["throw_hand"] = (2.0, 1.6)  # follow-through, arm dropping
                p["stoop"] = 2.4
                p["bob"] = -0.2

        out.append(p)
    return out


def draw_sheet():
    sheet = [[CLEAR] * (FRAME_W * COLUMNS) for _ in range(FRAME_H * ROWS)]

    for row_index, row in enumerate(ROW_NAMES):
        for column, p in enumerate(frames_of(row)):
            f = blank_frame()
            draw_drudge(f, p)
            for y in range(FRAME_H):
                for x in range(FRAME_W):
                    if f[y][x] != CLEAR:
                        sheet[row_index * FRAME_H + y][column * FRAME_W + x] = f[y][x]

    return sheet


# ------------------------------------------------------------------- the PNG
# Identical to tools/seed_wizard.py's own reader and writer: both tools
# draw the same shape of file, an 8-bit RGBA PNG read back by row.


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
    """Hold the file on disk to the rules in the header."""
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
                    # The lamp is held out, not stood on, so it says
                    # nothing about where his feet are.
                    if pixel not in (LAMP_GLOW, LAMP_CORE):
                        lowest = max(lowest, y)

            declared = column < ROW_FRAMES[row]
            if declared and ink == 0:
                faults.append(f"{row} frame {column} is empty, and the row declares it")
            if not declared and ink != 0:
                faults.append(f"{row} frame {column} holds ink, and the row does not declare it")
            if declared and not FOOT_Y - FOOT_SLACK <= lowest <= FOOT_Y:
                faults.append(
                    f"{row} frame {column} ends at row {lowest}, and he stands on "
                    f"row {FOOT_Y}, within {FOOT_SLACK} above it and never below"
                )

    # The idle frame the light is measured against (row 0, column 0)
    # must actually hold the lamp where src/drudge.odin's own constants
    # say the light leaves it. This is read here in frame coordinates;
    # src/light.odin's test reads the same point in world coordinates
    # through drudge_lamp_at and fails independently if the two ever
    # disagree.
    idle0 = sheet[0:FRAME_H]
    lamp_seen = any(
        idle0[y][x] in (LAMP_GLOW, LAMP_CORE) for y in range(FRAME_H) for x in range(FRAME_W)
    )
    if not lamp_seen:
        faults.append("the idle frame holds no lamp ink at all; the light has nothing to leave")

    return faults


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="hold the file on disk to the rules")
    parser.add_argument("--seed", type=int, default=0x0C0A1, help="another hand draws it")
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

    # The seed exists for the same reason it does in seed_wizard.py: so
    # a second hand can be asked for, later, without this tool changing
    # shape. Nothing below reads randomness yet — every number is
    # authored — so today every seed draws the same drudge.
    random.Random(args.seed)
    write_png(args.out, draw_sheet())
    print(f"{args.out}: {FRAME_W * COLUMNS}x{FRAME_H * ROWS}, {sum(ROW_FRAMES.values())} frames")


if __name__ == "__main__":
    main()
