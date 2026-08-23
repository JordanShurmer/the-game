#!/usr/bin/env python3
"""Paint the homelands: the surface the wizard starts on, and the mouth
that takes him under it.

    tools/seed_homelands.py           # draws the twelve homelands and the cavemouth
    tools/seed_homelands.py --check   # holds the files on disk to the rules

The homelands are six regions of `generator = image` biome laid west to
east along the surface row of data/biome_map.png, drawn from a set of
twelve pictures. The world picks one picture per region off the world
seed, so the six the player walks are six of the twelve and another seed
gives another six. East of the last one is the Cavemouth region, one
picture, which is where the fields end and the coal begins.

Each picture is one region: 512 by 512 cells, one pixel a cell, in the
material colours of data/materials.txt, exactly as a gallery is.

WHAT IT DRAWS

Ground, and what people put on it. From the top of the picture down:

  - air, to the grass line;
  - a skin of Grass two to four cells thick, following a height field
    that rolls a dozen cells either way across the picture;
  - Dirt, deepening, with stones and gravel lenses in it further down;
  - the bottom edge, which meets the Coalmine region under it.

On top of that go plots, in a row across the picture. A plot is either
a field or a homestead:

  - a FIELD is tilled ground -- Loam ridges with a furrow between them,
    a hand's width apart -- with Wheat standing on the ridges, hedged or
    fenced at both ends. Some fields are fallow: ridges and no crop.
  - a HOME is a small brick cottage: a Rock footing, Brick walls a
    course thick, a door tall enough for a wizard to walk through, two
    shuttered windows, a Wood floor, a Wood ridge beam, and a Thatch
    roof pitched over it with the eaves overhanging. A chimney of Brick
    stands off the ridge.

Between the plots run a gravel path, fence lines, hay stooks, a stone
well, and the odd tree. That is the whole vocabulary.

THE TWO RULES IT MUST NOT BREAK

**The side edges of every picture must agree.** Two homelands regions
sit next to each other and the world does not blend them, so column 511
of one is beside column 0 of the next. Every picture therefore draws the
outermost EDGE columns identically: level ground at EDGE_GROUND, grass
on it, dirt under it. The height field is faded to that level before it
reaches them. `--check` reads the files back and holds them to it.

**The middle of the picture is the village green, and stays open.** The
wizard starts in the fourth homelands region, at the middle of it, and
`pond_place` digs the pond POND_AWAY (96) cells west of wherever he
stands. So the band from GREEN_X0 to GREEN_X1 carries no building and no
crop -- pasture, a path, a fence and nothing that a pond eating a hole
in it would spoil. `--check` holds the files to that too.

See docs/homelands.md for the whole design note.
"""

import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import museum

IMG = museum.IMG  # 512: one region, cells_per_pixel in data/biomes.txt

HOME_PATHS = [f"data/rooms/homelands_{i}.png" for i in range(12)]
MOUTH_PATH = "data/rooms/cavemouth_0.png"

# ------------------------------------------------------------ the ground

EDGE = 10  # columns at each side drawn the same in every picture
EDGE_GROUND = 168  # the row the grass starts on, at both side edges
ROLL = 13  # how far the height field wanders either side of that
SKIN = 3  # cells of Grass over the dirt

# The village green: no cottage and no crop stands between these two,
# because the wizard lands in the middle of it.
GREEN_X0 = 112
GREEN_X1 = 292

# And two spans inside the green are plain pasture, holding nothing at
# all above the grass but the track across it. POND is what the pond
# eats -- `pond_place` digs it POND_AWAY (96) cells west of him and it
# spans POND_RX + POND_SHELL (31) either way. YARD is where he lands.
POND_X0, POND_X1 = 118, 202
YARD_X0, YARD_X1 = 232, 280

# What a plain span may hold: soil, and the track worn across it.
PLAIN = ("Air", "Grass", "Dirt", "Rock", "Gravel", "Coal")
# What may not stand on the green at all: a building or a crop.
BUILT = ("Brick", "Thatch", "Wheat")

# The strata under the fields, as (first row, material). The homelands
# sit on deep earth and the only way down is the cavemouth, so nothing
# here is hollow: what a shaft dug from a field passes through is
# topsoil, then subsoil with stones in it, then a gravel band, then the
# rock that roofs the coalmine in the region below.
STRATA = (
    (0, "Dirt"),  # subsoil, from the grass down
    (300, "Dirt"),  # stones start here
    (392, "Gravel"),  # the gravel band
    (436, "Rock"),  # the roof of the mine
)
STONE_TOP = 300  # no stone in the soil above this row
GRAVEL_TOP = 392  # the gravel band, and the rock under it
ROCK_TOP = 436

# The cavemouth: where the bluff starts climbing out of the last field,
# and how far it rises above the grass line at the east edge.
BLUFF_X0 = 190
FACE = 78  # the scarp at the foot of it, over the level of the fields

# ------------------------------------------------------------ the buildings

WALL = 5  # cells the brick wall of a cottage is thick
FOOTING = 4  # cells of rock under the wall
DOOR_W = 14  # a door is wider than the wizard (8) and he walks in
DOOR_H = 18  # and taller than he is (13), with room over his hat
WINDOW = 9  # a window opening, square
EAVES = 7  # how far the thatch oversails the wall
THATCH_T = 7  # how thick the thatch is on the slope

AIR = "Air"
GRASS = "Grass"
DIRT = "Dirt"
LOAM = "Loam"
WHEAT = "Wheat"
BRICK = "Brick"
THATCH = "Thatch"
WOOD = "Wood"
ROCK = "Rock"
GRAVEL = "Gravel"
COAL = "Coal"


# --------------------------------------------------------------- the noise


class Rng:
    """A small deterministic generator, so a picture is the same picture
    every run and picture 7 is never picture 6."""

    def __init__(self, seed):
        self.state = (seed * 2654435761 + 0x9E3779B9) & 0xFFFFFFFF
        for _ in range(4):
            self.next()

    def next(self):
        x = self.state
        x ^= (x << 13) & 0xFFFFFFFF
        x ^= x >> 17
        x ^= (x << 5) & 0xFFFFFFFF
        self.state = x & 0xFFFFFFFF
        return self.state

    def unit(self):
        return self.next() / 0x100000000

    def below(self, n):
        return self.next() % n

    def between(self, lo, hi):
        """An integer in [lo, hi]."""
        return lo + self.below(hi - lo + 1)

    def chance(self, p):
        return self.unit() < p

    def pick(self, items):
        return items[self.below(len(items))]


def smooth_field(rng, length, wavelength, amplitude):
    """A wandering line: random values a wavelength apart, joined by a
    cosine so the ground rolls instead of stepping."""
    import math

    stops = length // wavelength + 2
    highs = [rng.unit() * 2.0 - 1.0 for _ in range(stops)]
    out = []
    for x in range(length):
        i = x // wavelength
        t = (x % wavelength) / wavelength
        t = (1.0 - math.cos(t * math.pi)) * 0.5
        out.append((highs[i] * (1.0 - t) + highs[i + 1] * t) * amplitude)
    return out


# -------------------------------------------------------------- the canvas


class Land:
    """A region of material names, and the height of the ground in every
    column of it."""

    def __init__(self, seed):
        self.rng = Rng(seed)
        self.cells = [[AIR] * IMG for _ in range(IMG)]
        self.top = [EDGE_GROUND] * IMG

    # -- writing

    def set(self, x, y, name):
        if 0 <= x < IMG and 0 <= y < IMG:
            self.cells[y][x] = name

    def at(self, x, y):
        if 0 <= x < IMG and 0 <= y < IMG:
            return self.cells[y][x]
        return AIR

    def fill(self, x0, y0, x1, y1, name):
        for y in range(max(0, y0), min(IMG - 1, y1) + 1):
            row = self.cells[y]
            for x in range(max(0, x0), min(IMG - 1, x1) + 1):
                row[x] = name

    def column(self, x, y0, y1, name):
        self.fill(x, y0, x, y1, name)

    def outline(self, x0, y0, x1, y1, name, t=1):
        self.fill(x0, y0, x1, y0 + t - 1, name)
        self.fill(x0, y1 - t + 1, x1, y1, name)
        self.fill(x0, y0, x0 + t - 1, y1, name)
        self.fill(x1 - t + 1, y0, x1, y1, name)

    # -- reading the ground

    def ground(self, x):
        return self.top[min(max(x, 0), IMG - 1)]

    def level(self, x0, x1):
        """The lowest ground line across a span: what a building must
        stand on if it is not to hang in the air at one end."""
        return max(self.ground(x) for x in range(max(0, x0), min(IMG - 1, x1) + 1))


def edge_profile():
    """What every picture must hold in its outermost columns: level
    ground at EDGE_GROUND, the grass on it, and the strata under it. It
    is one column, and both the drawing and the gate read it from here,
    so the two can never drift apart."""
    out = [AIR] * IMG
    for y in range(EDGE_GROUND, EDGE_GROUND + SKIN):
        out[y] = GRASS
    for y in range(EDGE_GROUND + SKIN, IMG):
        out[y] = stratum_at(y)
    return out


def stratum_at(y):
    """Which stratum a row is in."""
    name = STRATA[0][1]
    for first, material in STRATA:
        if y >= first:
            name = material
    return name


def stamp_edges(land, sides="both"):
    """The outermost columns, written last and identically in every
    picture, the way a wang tile's bands are. Whatever the picture drew
    there is overwritten, so a field simply ends in a headland at the
    region border."""
    columns = []
    if sides in ("both", "west"):
        columns += list(range(EDGE))
    if sides in ("both", "east"):
        columns += list(range(IMG - EDGE, IMG))
    want = edge_profile()
    for x in columns:
        for y in range(IMG):
            land.cells[y][x] = want[y]
        land.top[x] = EDGE_GROUND


def lay_ground(land):
    """The soil: a rolling grass line, faded flat before it reaches the
    side edges so two regions meet without a step."""
    roll = smooth_field(land.rng, IMG, 84, ROLL)
    fine = smooth_field(land.rng, IMG, 23, 2.2)

    for x in range(IMG):
        # Fade to the shared edge level over the last FADE columns, so
        # column 0 and column 511 are the same in every picture.
        FADE = 56
        near = min(x, IMG - 1 - x)
        hold = 0.0 if near < EDGE else min(1.0, (near - EDGE) / FADE)
        land.top[x] = int(round(EDGE_GROUND + (roll[x] + fine[x]) * hold))

    for x in range(IMG):
        top = land.top[x]
        land.fill(x, top, x, top + SKIN - 1, GRASS)
        for y in range(top + SKIN, IMG):
            land.cells[y][x] = stratum_at(y)

    scatter_soil(land)


def scatter_soil(land):
    """What is in the ground under a field: stones, and lenses of gravel
    where the soil gives way to the coal under the region."""
    rng = land.rng
    # Stones turned up in the subsoil, more of them the deeper it goes.
    for _ in range(44):
        cx = rng.between(EDGE + 12, IMG - EDGE - 13)
        cy = rng.between(STONE_TOP, GRAVEL_TOP)
        blob(land, cx, cy, rng.between(3, 8), ROCK)

    # The gravel band is not a ruled line: it wanders, and lenses of it
    # reach up into the soil and down into the rock.
    for _ in range(30):
        cx = rng.between(EDGE + 16, IMG - EDGE - 17)
        cy = rng.between(GRAVEL_TOP - 22, GRAVEL_TOP + 30)
        blob(land, cx, cy, rng.between(5, 14), GRAVEL, flat=2.6)

    # And coal in the rock that roofs the mine, which is the first sight
    # of what the region under this one is made of.
    for _ in range(20):
        cx = rng.between(EDGE + 10, IMG - EDGE - 11)
        cy = rng.between(ROCK_TOP, IMG - 4)
        blob(land, cx, cy, rng.between(4, 11), COAL, flat=2.2)


def blob(land, cx, cy, r, name, flat=1.0):
    """A rounded lump, wider than it is tall when flat is over one, and
    only ever written into ground that is already there."""
    for y in range(cy - r, cy + r + 1):
        for x in range(cx - int(r * flat) - 1, cx + int(r * flat) + 2):
            dx = (x - cx) / flat
            dy = y - cy
            if dx * dx + dy * dy > r * r:
                continue
            if land.at(x, y) in (AIR, GRASS):
                continue
            land.set(x, y, name)


# --------------------------------------------------------------- the field


def plough(land, x0, x1, fallow):
    """Tilled ground: ridges of loam with a furrow between them. A ridge
    stands a little proud of the grass and the furrow cuts into it, which
    is what makes a worked field read as worked from a distance."""
    rng = land.rng
    period = rng.pick([7, 8, 9])
    x = x0
    while x <= x1:
        ridge = min(x + period - 3, x1)
        top = land.level(x, ridge)
        # The ridge: loam heaped a little over the grass line.
        land.fill(x, top - 2, ridge, top + 13, LOAM)
        # The furrow beside it, cut down into the loam.
        land.fill(ridge + 1, top + 1, min(x + period - 1, x1), top + 13, LOAM)
        land.fill(ridge + 1, top - 2, min(x + period - 1, x1), top, AIR)
        x += period

    if fallow:
        return

    x = x0 + 1
    while x <= x1 - 1:
        if rng.chance(0.10):
            x += rng.between(2, 5)
            continue
        stem = land.ground(x) - 3
        h = rng.between(11, 17)
        land.fill(x, stem - h, x, stem, WHEAT)
        # The ear: a couple of cells wider at the top of the stalk.
        land.fill(x - 1, stem - h, x + 1, stem - h + rng.between(2, 4), WHEAT)
        x += rng.between(2, 3)


def hedge(land, x, height=None):
    """A line of grass grown up between two plots."""
    rng = land.rng
    h = height or rng.between(9, 15)
    for dx in (-1, 0, 1):
        top = land.ground(x + dx)
        land.fill(x + dx, top - h + abs(dx) * 2, x + dx, top, GRASS)


def fence(land, x0, x1):
    """Posts and two rails of wood, following the ground."""
    rng = land.rng
    rail_hi = 12
    rail_lo = 6
    for x in range(x0, x1 + 1):
        top = land.ground(x)
        if (x - x0) % 22 < 2:
            land.fill(x, top - 15, x, top, WOOD)
        else:
            land.set(x, top - rail_hi, WOOD)
            land.set(x, top - rail_lo, WOOD)
        _ = rng


# ------------------------------------------------------------- the cottage


def cottage(land, x0, w):
    """A small brick home, standing on the ground under it.

    The section, from the outside in: a rock footing sunk into the
    ground, a brick wall a course thick, and the room. Over it a thatch
    roof on a wood ridge, oversailing the wall at the eaves. A door and
    two shuttered windows are cut back out of the wall."""
    rng = land.rng
    x1 = x0 + w - 1
    floor = land.level(x0 - EAVES, x1 + EAVES)
    h = rng.between(30, 38)  # wall height, floor to eaves
    top = floor - h

    # Dig the footing into the ground and stand the shell on it.
    land.fill(x0, floor, x1, floor + FOOTING, ROCK)
    land.fill(x0, top, x1, floor - 1, BRICK)
    land.fill(x0 + WALL, top + WALL, x1 - WALL, floor - 1, AIR)
    land.fill(x0 + WALL, floor - 2, x1 - WALL, floor - 1, WOOD)  # the floor boards

    # The door, in the half of the front the windows are not in.
    door_x = x0 + WALL + 3 if rng.chance(0.5) else x1 - WALL - 2 - DOOR_W
    land.fill(door_x, floor - DOOR_H, door_x + DOOR_W - 1, floor - 1, AIR)
    land.fill(door_x - 1, floor - DOOR_H - 1, door_x + DOOR_W, floor - DOOR_H - 1, WOOD)
    land.column(door_x - 1, floor - DOOR_H - 1, floor - 1, WOOD)
    land.column(door_x + DOOR_W, floor - DOOR_H - 1, floor - 1, WOOD)

    # Windows: openings with a wood sill and lintel, on whichever side
    # of the door has room for them.
    sill = floor - DOOR_H + 2
    for wx in (x0 + WALL + 3, x1 - WALL - 2 - WINDOW):
        if wx + WINDOW >= door_x - 3 and wx <= door_x + DOOR_W + 3:
            continue
        land.fill(wx, sill - WINDOW, wx + WINDOW - 1, sill - 1, AIR)
        land.fill(wx - 1, sill - WINDOW - 1, wx + WINDOW, sill - WINDOW - 1, WOOD)
        land.fill(wx - 1, sill, wx + WINDOW, sill, WOOD)

    roof(land, x0, x1, top, rng)
    return floor


def roof(land, x0, x1, eave_y, rng):
    """A pitched thatch roof: a wood ridge beam, rafters implied by the
    slope of the thatch itself, and eaves that oversail the wall so the
    wall is in the roof's shadow."""
    left = x0 - EAVES
    right = x1 + EAVES
    span = right - left
    mid = (left + right) // 2
    pitch = rng.between(45, 62) / 100.0
    ridge_y = eave_y - int(span * 0.5 * pitch)

    for x in range(left, right + 1):
        t = abs(x - mid) / (span * 0.5)
        y = int(ridge_y + (eave_y - ridge_y) * t)
        land.fill(x, y, x, y + THATCH_T - 1, THATCH)

    # The ridge itself: a course of wood along the top, and a wood
    # bargeboard closing each end of the thatch.
    land.fill(mid - 2, ridge_y - 1, mid + 2, ridge_y + 1, WOOD)
    land.fill(left, eave_y + THATCH_T - 2, left + 2, eave_y + THATCH_T - 1, WOOD)
    land.fill(right - 2, eave_y + THATCH_T - 2, right, eave_y + THATCH_T - 1, WOOD)

    # The gable under the thatch is brick, so the roof is closed at the
    # ends rather than open to the sky.
    for x in range(x0, x1 + 1):
        t = abs(x - mid) / (span * 0.5)
        y = int(ridge_y + (eave_y - ridge_y) * t)
        land.fill(x, y + THATCH_T, x, eave_y - 1, BRICK)

    chimney(land, x0, x1, ridge_y, eave_y, rng)


def chimney(land, x0, x1, ridge_y, eave_y, rng):
    cx = x0 + 6 if rng.chance(0.5) else x1 - 12
    top = ridge_y - rng.between(8, 16)
    land.fill(cx, top, cx + 6, eave_y + 4, BRICK)
    land.fill(cx + 2, top, cx + 4, top + 3, AIR)  # the flue
    land.fill(cx - 1, top, cx + 7, top + 2, BRICK)  # the cap, wider than the stack


# ----------------------------------------------------------- the small things


def well(land, x):
    """A stone well: a ring of rock standing over a shaft, with a wood
    windlass across it."""
    top = land.level(x, x + 15)
    land.fill(x, top - 11, x + 15, top + 2, ROCK)
    land.fill(x + 4, top - 11, x + 11, IMG - 1, AIR)
    land.fill(x + 4, top + 40, x + 11, IMG - 1, DIRT)
    land.fill(x, top - 13, x + 15, top - 12, ROCK)  # the coping
    land.fill(x + 1, top - 22, x + 2, top - 13, WOOD)  # the posts
    land.fill(x + 13, top - 22, x + 14, top - 13, WOOD)
    land.fill(x + 1, top - 24, x + 14, top - 23, WOOD)  # the beam
    land.fill(x + 6, top - 22, x + 9, top - 20, WOOD)  # the windlass


def stook(land, x):
    """A stook of cut wheat, leaned together and standing in the field."""
    top = land.ground(x)
    for i, dx in enumerate((-3, -1, 1, 3)):
        lean = (i - 1.5) * 0.9
        for k in range(14):
            land.set(int(x + dx + lean * k * 0.16), top - k, WHEAT)


def tree(land, x):
    """A tree: a wood trunk and a crown of grass, which is the only leaf
    the world has."""
    rng = land.rng
    top = land.ground(x)
    h = rng.between(28, 40)
    land.fill(x - 1, top - h, x + 1, top, WOOD)
    cy = top - h - 6
    r = rng.between(13, 18)
    for y in range(cy - r, cy + r + 1):
        for cx in range(x - r, x + r + 1):
            dx = (cx - x) / 1.15
            dy = (y - cy) / 0.92
            if dx * dx + dy * dy <= r * r and land.at(cx, y) == AIR:
                land.set(cx, y, GRASS)


def path(land, x0, x1):
    """A gravel track worn through the grass."""
    for x in range(x0, x1 + 1):
        top = land.ground(x)
        land.fill(x, top, x, top + 2, GRAVEL)


# ----------------------------------------------------------- laying a picture


def span_of(rng, x0, x1):
    """Fill one span with plots, end to end, with a gap between them. A
    plot is a start, a width and a kind."""
    out = []
    x = x0 + rng.between(2, 12)
    while x1 - x > 34:
        room = x1 - x
        if room > 92 and rng.chance(0.45):
            w = rng.between(62, min(86, room - 4))
            out.append((x, w, "home"))
        else:
            w = rng.between(34, min(96, room - 2))
            out.append((x, w, "field"))
        x += w + rng.between(8, 18)
    return out


# A cottage oversails its own footprint by the eaves, and a fence run
# reaches past the plot it closes, so a plot span stops short of the
# green by this much.
MARGIN = EAVES + 4


def plots(rng):
    """The row of plots across one picture, west of the green and east
    of it, each with the span it may not reach out of."""
    west = (EDGE + 2, GREEN_X0 - 1 - MARGIN)
    east = (GREEN_X1 + 1 + MARGIN, IMG - EDGE - 3)
    return [(west, span_of(rng, west[0], west[1])), (east, span_of(rng, east[0], east[1]))]


def paint_homeland(seed):
    land = Land(seed)
    rng = land.rng
    lay_ground(land)

    for (lo, hi), row in plots(rng):
        for x, w, kind in row:
            if kind == "home":
                cottage(land, x, w)
                if rng.chance(0.5):
                    fence(land, min(x + w + EAVES + 2, hi), min(x + w + EAVES + 22, hi))
            else:
                plough(land, x, x + w - 1, fallow=rng.chance(0.28))
                if rng.chance(0.55):
                    hedge(land, max(x - 3, lo))
                if rng.chance(0.45):
                    stook(land, x + rng.between(6, max(7, w - 6)))

    # The green: a gravel track worn the length of it, and off the track
    # a fence line, a well or a tree, but never over the pond and never
    # in the yard he lands in.
    path(land, GREEN_X0 + 2, GREEN_X1 - 2)
    if rng.chance(0.7):
        fence(land, POND_X1 + 4, YARD_X0 - 6)
    if rng.chance(0.5):
        well(land, YARD_X1 + 3)
    if rng.chance(0.5):
        tree(land, GREEN_X0 - 34)

    stamp_edges(land)
    return land


def carve(land, cx, cy, r, flat=1.0):
    """Take a rounded bite out of whatever is there."""
    for y in range(cy - r - 1, cy + r + 2):
        for x in range(cx - int(r * flat) - 1, cx + int(r * flat) + 2):
            dx = (x - cx) / flat
            dy = y - cy
            if dx * dx + dy * dy <= r * r:
                land.set(x, y, AIR)


def carve_run(land, points):
    """Walk a line of (x, y, radius) waypoints and carve a tube along
    it, so a passage widens and turns as it goes instead of stepping."""
    for i in range(len(points) - 1):
        x0, y0, r0 = points[i]
        x1, y1, r1 = points[i + 1]
        steps = max(abs(x1 - x0), abs(y1 - y0), 1)
        for k in range(steps + 1):
            t = k / steps
            carve(land, int(x0 + (x1 - x0) * t), int(y0 + (y1 - y0) * t), int(r0 + (r1 - r0) * t))


def paint_cavemouth():
    """Where the fields end.

    The last headland runs east into a hillside that climbs the whole
    height of the region, so at the east edge the ground stands at the
    top of the picture -- which is exactly where the Coalmine region
    beside it starts, and the two meet with no step. A mouth opens in
    the lower face of that hillside at the height a wizard walks in at,
    and the passage behind it turns down into the coal."""
    land = Land(0xCA7E)
    rng = land.rng
    lay_ground(land)

    # The hillside. It does not start level with the fields: it starts
    # as a scarp FACE cells high, because a mouth needs a face to open
    # in and a slope has none. From the top of that scarp it climbs on
    # to the top of the region, where the coal begins.
    roll = smooth_field(rng, IMG, 60, 6)
    scarp = smooth_field(rng, IMG, 21, 4)
    for x in range(BLUFF_X0, IMG):
        t = (x - BLUFF_X0) / (IMG - 1 - BLUFF_X0)
        foot = EDGE_GROUND - FACE
        climb = t ** 0.6
        crest = int(foot * (1.0 - climb) + roll[x] * (1.0 - abs(2 * t - 1)) + scarp[x] * (1.0 - t))
        crest = max(0, min(EDGE_GROUND, crest))
        land.fill(x, 0, x, crest - 1, AIR)
        land.fill(x, crest, x, IMG - 1, ROCK)
        # Soil and grass hold on the lower slope and give out further up.
        if t < 0.42:
            land.fill(x, crest, x, crest + SKIN - 1, GRASS)
            land.fill(x, crest + SKIN, x, crest + SKIN + int((0.42 - t) * 40), DIRT)
        land.top[x] = crest

    # The mouth, and the passage behind it: in level at the height of
    # the fields, then back and down under the hill, widening the whole
    # way to the cavern at the bottom.
    carve_run(
        land,
        (
            (BLUFF_X0 - 8, EDGE_GROUND - 17, 19),
            (BLUFF_X0 + 54, EDGE_GROUND - 15, 21),
            (BLUFF_X0 + 116, EDGE_GROUND + 40, 27),
            (BLUFF_X0 + 168, EDGE_GROUND + 150, 34),
            (BLUFF_X0 + 196, IMG - 96, 42),
        ),
    )

    # The cavern the passage lets out into. It is open along the whole
    # bottom edge, so the coal in the region under this one is met
    # whatever tile the world lays there.
    carve_run(land, ((30, IMG - 52, 30), (200, IMG - 64, 42), (IMG - 1, IMG - 46, 38)))
    land.fill(30, IMG - 30, IMG - 1, IMG - 1, AIR)
    for _ in range(7):
        cx = rng.between(70, IMG - 60)
        land.fill(cx, IMG - 80, cx + rng.between(4, 9), IMG - 1, ROCK)  # pillars

    # Cave in the hill east of the passage, so the coalmine beside this
    # region is met by cave and not by a wall of rock.
    for _ in range(16):
        cx = rng.between(IMG - 150, IMG - 1)
        cy = rng.between(EDGE_GROUND - 60, IMG - 100)
        carve(land, cx, cy, rng.between(10, 26), flat=1.5)

    # The floor of the entrance, worn to gravel by the people who use it.
    for x in range(BLUFF_X0 - 44, BLUFF_X0 + 66):
        for y in range(EDGE_GROUND - 30, IMG):
            if land.at(x, y) in (ROCK, DIRT, GRASS):
                land.fill(x, y, x, y + 2, GRAVEL)
                break

    # Coal in the rock, so the reason to go down is visible from inside
    # the mouth.
    for _ in range(40):
        cx, cy = rng.between(BLUFF_X0, IMG - 6), rng.between(20, IMG - 20)
        if land.at(cx, cy) == ROCK:
            blob(land, cx, cy, rng.between(3, 8), COAL, flat=2.4)

    stamp_edges(land, sides="west")
    return land


# ------------------------------------------------------------------- the gate


def check_one(path_name, materials, is_mouth):
    faults = []
    if not os.path.exists(path_name):
        return [f"{path_name} does not exist; run this tool with no arguments"]

    by_color = {}
    for name, (rgba, _) in materials.items():
        by_color[rgba] = name

    width, height, rows = museum.read_png(path_name)
    if (width, height) != (IMG, IMG):
        return [f"{path_name} is {width}x{height}, and a region is {IMG} square"]

    grid = []
    for y, row in enumerate(rows):
        out = []
        for x, px in enumerate(row):
            name = by_color.get(tuple(px))
            if name is None:
                faults.append(f"{path_name}: cell {x},{y} is {tuple(px)}, which is no material")
                name = AIR
            out.append(name)
        grid.append(out)
    if faults:
        return faults

    if is_mouth:
        return faults + check_mouth(path_name, grid)
    return faults + check_homeland(path_name, grid)


def check_homeland(path_name, grid):
    faults = []
    want = edge_profile()
    for x in list(range(EDGE)) + list(range(IMG - EDGE, IMG)):
        for y in range(IMG):
            if grid[y][x] != want[y]:
                faults.append(
                    f"{path_name}: column {x} row {y} is {grid[y][x]} and every picture"
                    f" must hold {want[y]} there, or two regions meet in a step"
                )
                break

    for x in range(GREEN_X0, GREEN_X1 + 1):
        for y in range(IMG):
            if grid[y][x] in BUILT:
                faults.append(
                    f"{path_name}: {grid[y][x]} at {x},{y} stands on the village green"
                    f" ({GREEN_X0}..{GREEN_X1}), where the wizard lands"
                )
                break

    for x0, x1, what in ((POND_X0, POND_X1, "the pond"), (YARD_X0, YARD_X1, "the yard")):
        for x in range(x0, x1 + 1):
            for y in range(IMG):
                if grid[y][x] not in PLAIN:
                    faults.append(
                        f"{path_name}: {grid[y][x]} at {x},{y} is in {what}"
                        f" ({x0}..{x1}), which must be plain pasture"
                    )
                    break
    return faults


def check_mouth(path_name, grid):
    """The mouth must be walkable in from the west, and open at the
    bottom, or the caves are not entered from the homelands."""
    faults = []
    want = edge_profile()
    for y in range(IMG):
        for x in range(EDGE):
            if grid[y][x] != want[y]:
                faults.append(
                    f"{path_name}: column {x} row {y} is {grid[y][x]} and must hold"
                    f" {want[y]}, or it does not meet the last homeland"
                )
                break

    open_bottom = sum(1 for x in range(IMG) if grid[IMG - 1][x] == AIR)
    if open_bottom < IMG // 2:
        faults.append(
            f"{path_name}: only {open_bottom} of {IMG} cells along the bottom edge are"
            " open, and the coalmine under it must be met"
        )

    # Walk the open space from the west edge at head height and see that
    # it reaches the bottom row.
    seen = [[False] * IMG for _ in range(IMG)]
    stack = [(0, EDGE_GROUND - 1)]
    reached = False
    while stack:
        x, y = stack.pop()
        if not (0 <= x < IMG and 0 <= y < IMG) or seen[y][x] or grid[y][x] != AIR:
            continue
        seen[y][x] = True
        if y == IMG - 1:
            reached = True
        stack.extend(((x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)))
    if not reached:
        faults.append(f"{path_name}: no open way from the west edge down to the coal under it")
    return faults


# ------------------------------------------------------------------- the CLI


def main():
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument("--check", action="store_true", help="hold the files on disk to the rules")
    args = parser.parse_args()

    if not os.path.exists(museum.MATERIALS_PATH):
        sys.exit("cannot read data/materials.txt; run this from the repository root")

    materials = museum.read_materials()

    if args.check:
        faults = []
        for name in HOME_PATHS:
            faults += check_one(name, materials, is_mouth=False)
        faults += check_one(MOUTH_PATH, materials, is_mouth=True)
        for fault in faults:
            print(fault, file=sys.stderr)
        if faults:
            sys.exit(1)
        print(f"{len(HOME_PATHS)} homelands and the cavemouth: every rule holds")
        return

    for i, name in enumerate(HOME_PATHS):
        land = paint_homeland(0x480E + i * 7919)
        museum.write_png(name, museum.render(land, materials))
        print(f"{name}: {IMG}x{IMG}")

    museum.write_png(MOUTH_PATH, museum.render(paint_cavemouth(), materials))
    print(f"{MOUTH_PATH}: {IMG}x{IMG}")


if __name__ == "__main__":
    main()
