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
wizard starts in the fourth homelands region, at the middle of it. So
the band from GREEN_X0 to GREEN_X1 carries no building and no crop --
pasture, a path, a fence -- and the yard in the middle of it holds
nothing at all, so wherever the seed puts him down there is ground to
stand on. `--check` holds the files to that too.

See docs/homelands.md for the whole design note.
"""

import argparse
import math
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
ROLL = 13  # how far the fine height field wanders either side of that
SWELL = 26  # how far the long, slow ground swell adds on top of that, out
            # in the plot spans -- it is held at zero across the green,
            # below
GREEN_FADE = 70  # how gently the swell fades in from the edge of the green
GREEN_SALT = 0x6E7E5F31  # keys the green's own dice, apart from the plots'
SWELL_SALT = 0x51E11B0D  # keys the swell's own dice, apart from everything else
PLOT_SALT = 0x2F8C6A19  # keys the plots' own dice, apart from the ground's
STRATA_SALT = 0x7A19C3E5  # keys the gravel band's and rock roof's own wander
SKIN = 3  # cells of Grass standing over the soil line, not cut into it

# PLAYER_CLIMB in src/player.odin: the step a wizard takes without
# jumping. Anything on open ground that rises more than this is a wall
# to him, so the worked ground of a field -- ridges, furrows, hedge
# banks, ditches -- is all cut to it.
PLAYER_STEP = 3

# The village green: no cottage and no crop stands between these two,
# because the wizard lands in the middle of it.
GREEN_X0 = 112
GREEN_X1 = 292

# And one span inside the green is plain pasture, holding nothing at
# all above the grass but the track across it: the yard, where he
# lands. (A second span used to be held for the pond, which was dug
# into the green beside him; the pond is a tile in the caves now, and
# the green keeps only the pasture it always had.)
YARD_X0, YARD_X1 = 232, 280

# What a plain span may hold: soil, and the track worn across it.
PLAIN = ("Air", "Grass", "Dirt", "Rock", "Gravel", "Coal")

# What a wizard walks through rather than into: air, and the standing
# growth that `state = Brush` in data/materials.txt makes too slight to
# stop him.
WALKED_THROUGH = ("Air", "Grass", "Wheat")

# The ground itself, as against the things people built on it. A step up
# made of ground may never be higher than PLAYER_STEP: he cannot climb
# it and there is nothing about a field that should stop him. A step
# made of anything else is a wall, a roof, a fence or a woodpile, and he
# jumps those -- he clears about twenty-eight cells.
GROUND = ("Grass", "Dirt", "Loam", "Gravel", "Sand")
# What may not stand on the green at all: a building or a crop.
BUILT = ("Brick", "Thatch", "Wheat")

# The strata under the fields, as (first row, material). The homelands
# sit on deep earth and the only way down is the cavemouth, so nothing
# here is hollow: what a shaft dug from a field passes through is
# topsoil, then subsoil with stones in it, then a gravel band, then the
# rock that roofs the coalmine in the region below.
STRATA = (
    (0, "Dirt"),  # subsoil, from the grass down
    (392, "Gravel"),  # the gravel band
    (436, "Rock"),  # the roof of the mine
)
STONE_TOP = 300  # stones start here: no stone in the soil above this row
GRAVEL_TOP = 392  # the gravel band, and the rock under it
ROCK_TOP = 436

# The cavemouth: where the bluff starts climbing out of the last field,
# and how far it rises above the grass line at the east edge.
BLUFF_X0 = 190
FACE = 78  # the scarp at the foot of it, over the level of the fields
BLUFF_BLEND = 120  # how far west of the bluff a tongue of its rock may reach
ADIT_X0 = BLUFF_X0 - 34  # where the mouth is cut, west of the face, so what
                         # is heaped outside it can never bury it
ADIT_LEN = 96  # cells the mouth runs square and worked before the natural cave
ADIT_HALF_W = 19  # half the squared adit's width
ADIT_HALF_H = 17  # half the squared adit's height

# ------------------------------------------------------------ the buildings

WELL_DEPTH = 40  # cells of dry shaft under the coping of a well

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
        self.seed = seed
        self.rng = Rng(seed)
        self.cells = [[AIR] * IMG for _ in range(IMG)]
        self.ploughed = [False] * IMG
        self.top = [EDGE_GROUND] * IMG
        # How far the gravel band and the rock roof have wandered from
        # their flat rows in each column, set by lay_ground and read
        # back by scatter_soil and stratum_at_col.
        self.gravel_wander = [0.0] * IMG
        self.rock_wander = [0.0] * IMG

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

    # -- reading the ground

    def ground(self, x):
        return self.top[min(max(x, 0), IMG - 1)]

    def level(self, x0, x1):
        """The lowest ground line across a span: what a building must
        stand on if it is not to hang in the air at one end."""
        return max(self.ground(x) for x in range(max(0, x0), min(IMG - 1, x1) + 1))


def edge_profile():
    """What every picture must hold in its outermost columns: level
    ground at EDGE_GROUND, the grass over it, and the strata under it.
    It is one column, and both the drawing and the gate read it from
    here, so the two can never drift apart.

    EDGE_GROUND is the *soil* line, and the grass stands on top of it
    rather than being the top of it. Grass is `state = Brush`, which a
    wizard walks through, so it does not hold him up: the soil under it
    does. Grown the other way -- a soil line three cells under the grass
    -- every solid thing laid at the ground line stood on a three cell
    pedestal, and walking off a meadow onto a footpath was a step he
    could not take."""
    out = [AIR] * IMG
    for y in range(EDGE_GROUND - SKIN, EDGE_GROUND):
        out[y] = GRASS
    for y in range(EDGE_GROUND, IMG):
        out[y] = stratum_at(y)
    return out


def stratum_at(y):
    """Which stratum a row is in, at the flat row it always sat on."""
    name = STRATA[0][1]
    for first, material in STRATA:
        if y >= first:
            name = material
    return name


def stratum_at_col(land, x, y):
    """Which stratum a row is in at this column: the gravel band and
    the rock roof wander gently from column to column instead of
    running dead level like a layer cake, using the offsets lay_ground
    left on `land`. Those offsets are faded to zero at the picture's
    edges, so at EDGE this is `stratum_at` again and the shared edge
    profile still holds."""
    gt = GRAVEL_TOP + int(land.gravel_wander[x])
    rt = ROCK_TOP + int(land.rock_wander[x])
    rt = max(rt, gt + 14)  # the rock roof never rides up into the gravel band
    if y >= rt:
        return ROCK
    if y >= gt:
        return GRAVEL
    return stratum_at(y)  # topsoil/subsoil above the band: plain Dirt either way


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


def swell_hold(x):
    """Zero across the village green, where the ground must stay at the
    height it has always stood, fading up to full strength out where
    the plots are, so there is no step at the edge of the green."""
    if GREEN_X0 <= x <= GREEN_X1:
        return 0.0
    d = (GREEN_X0 - x) if x < GREEN_X0 else (x - GREEN_X1)
    return min(1.0, d / GREEN_FADE)


def lay_ground(land):
    """The soil: a rolling grass line -- a long slow swell of banks and
    hollows out in the plot spans, with a finer roll on top of it that
    runs everywhere including the green -- faded flat before it reaches
    the side edges so two regions meet without a step."""
    # roll and fine are drawn from the picture's own stream, in the same
    # order and count the ground always drew them in, so every random
    # choice downstream of them -- the stones in the soil, where the
    # plots fall, the roll of a hedge or a chimney -- is exactly what it
    # always was. swell is drawn from a stream of its own instead: it is
    # a later addition, and if it drew from land.rng its extra draws
    # would still shift everything after it even though it is held at
    # zero over the green -- the green would be level, but nothing past
    # it would be the picture it always was.
    roll = smooth_field(land.rng, IMG, 84, ROLL)
    fine = smooth_field(land.rng, IMG, 23, 2.2)
    swell = smooth_field(Rng(land.seed ^ SWELL_SALT), IMG, 190, SWELL)

    # The gravel band and the rock roof wander too, on a stream of
    # their own so a change here cannot perturb the ground or the
    # plots -- faded flat at the edges by the same `hold` the grass
    # line uses, so the strata a shot sees on either side of a region
    # border still agree.
    strata_rng = Rng(land.seed ^ STRATA_SALT)
    gravel_wander = smooth_field(strata_rng, IMG, 70, 24)
    rock_wander = smooth_field(strata_rng, IMG, 95, 20)

    for x in range(IMG):
        # Fade to the shared edge level over the last FADE columns, so
        # column 0 and column 511 are the same in every picture.
        FADE = 56
        near = min(x, IMG - 1 - x)
        hold = 0.0 if near < EDGE else min(1.0, (near - EDGE) / FADE)
        swell_amt = swell[x] * swell_hold(x)
        land.top[x] = round(EDGE_GROUND + (swell_amt + roll[x] + fine[x]) * hold)
        land.gravel_wander[x] = gravel_wander[x] * hold
        land.rock_wander[x] = rock_wander[x] * hold

    # No column of ground may stand more than a cell over the one beside
    # it. The height field is smooth almost everywhere on its own; this
    # makes it true everywhere, which is what leaves room to heap a
    # ridge two cells proud and still be inside a wizard's step of three.
    for _ in range(2):
        for x in range(1, IMG):
            land.top[x] = max(land.top[x], land.top[x - 1] - 1)
        for x in range(IMG - 2, -1, -1):
            land.top[x] = max(land.top[x], land.top[x + 1] - 1)

    for x in range(IMG):
        top = land.top[x]
        land.fill(x, top - SKIN, x, top - 1, GRASS)
        for y in range(top, IMG):
            land.cells[y][x] = stratum_at_col(land, x, y)

    scatter_soil(land)


def scatter_soil(land):
    """What is in the ground under a field: flecks of stone in the
    topsoil where the eye actually reaches, stones turned up deeper,
    and lenses of gravel where the soil gives way to the coal under
    the region."""
    rng = land.rng
    # Right under the grass, where the top of the picture actually
    # shows: fine flecks of stone and darker earth, not a blank fill.
    for _ in range(70):
        cx = rng.between(EDGE + 4, IMG - EDGE - 5)
        depth = rng.between(4, 80)
        cy = land.ground(cx) + depth
        blob(land, cx, cy, rng.between(1, 3), ROCK if rng.chance(0.6) else DIRT)

    # Stones turned up in the subsoil, more of them the deeper it goes,
    # laid in loose horizontal bands rather than scattered evenly, so
    # the strata read as layers.
    for _ in range(46):
        band = rng.between(0, 2)
        cy = rng.between(STONE_TOP + band * 34, STONE_TOP + band * 34 + 30)
        cx = rng.between(EDGE + 12, IMG - EDGE - 13)
        blob(land, cx, cy, rng.between(3, 9), ROCK, flat=rng.between(1, 3))

    # The gravel band is not a ruled line: it wanders, and lenses of it
    # reach up into the soil and down into the rock, flattened into
    # sedimentary lenses rather than round lumps, sampled around
    # wherever the band actually is at that column rather than the
    # flat row it used to sit on.
    for _ in range(34):
        cx = rng.between(EDGE + 16, IMG - EDGE - 17)
        gt = GRAVEL_TOP + int(land.gravel_wander[cx])
        cy = gt + rng.between(-26, 30)
        blob(land, cx, cy, rng.between(5, 14), GRAVEL, flat=rng.between(2, 4))

    # And coal in the rock that roofs the mine, which is the first
    # sight of what the region under this one is made of. Coal is
    # bedded: long, thin, near-level seams that pinch and swell along
    # their run, not round holes punched in the rock.
    for _ in range(18):
        cx = rng.between(EDGE + 20, IMG - EDGE - 21)
        rt = ROCK_TOP + int(land.rock_wander[cx])
        cy = rng.between(rt + 6, IMG - 8)
        coal_seam(land, cx, cy, rng)


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


def coal_seam(land, cx, cy, rng):
    """A bedded seam of coal: long, thin and near level, wandering
    gently up and down along its run and pinching to nothing at both
    ends instead of swelling into a round lump. It only ever replaces
    Rock, so a seam sits in the rock it was laid down in and never
    bleeds into the soil or the gravel either side of it."""
    length = rng.between(70, 170)
    thick = rng.between(3, 7)
    # A bed dips and rises over the length of itself, not every few
    # cells. One slow wave across the whole run, and a second half as
    # fast and a third as deep, so it is not a drawn sine either.
    slow = rng.between(1, 2) * math.pi / length
    fine = rng.between(3, 5) * math.pi / length
    phase = rng.unit() * 6.283
    x0 = cx - length // 2
    for i in range(length):
        x = x0 + i
        wob = 5.0 * math.sin(slow * i + phase) + 1.8 * math.sin(fine * i)
        y = cy + round(wob)
        t = i / max(1, length - 1)
        pinch = 1.0 - abs(2.0 * t - 1.0)  # 0 at both ends, 1 at the middle
        h = max(1, round(thick * (0.25 + 0.75 * pinch)))
        top = y - h // 2
        for dy in range(h):
            if land.at(x, top + dy) == ROCK:
                land.set(x, top + dy, COAL)


# --------------------------------------------------------------- the field


def plough(land, x0, x1, fallow):
    """Tilled ground: ridges of loam standing proud of the grass, with a
    furrow between them, and wheat standing on the ridge tops in ranks
    with the furrows bare between.

    Every column is heaped off the ground under *that* column rather
    than off the lowest ground across the ridge, so the field follows
    the roll of the land it is cut into and no two neighbours ever step
    more than RIDGE_H apart. Heaped off the span, a ridge on a slope
    stood six cells over the furrow beside it, which is twice a
    wizard's step, and a ploughed field was a flight of stairs he could
    not climb."""
    rng = land.rng
    period = rng.pick([12, 14, 16])
    ridge_w = period - 5  # the ridge is most of the period, the furrow the rest

    # A wizard is thirteen cells tall and steps up PLAYER_CLIMB (3) of
    # them, so the whole relief of a field is cut to two, leaving the
    # third as slack for the ground it is heaped on.
    RIDGE_H = 2
    DEPTH = 15  # how far down the turned loam goes

    # No column is ploughed twice. Two plots whose spans touch used to
    # turn the same ground over with different periods, and a crown of
    # one beside a furrow of the other stood four cells apart, which is
    # over a wizard's step.
    while x0 <= x1 and land.ploughed[x0]:
        x0 += 1
    while x1 >= x0 and land.ploughed[x1]:
        x1 -= 1
    if x1 - x0 < period:
        return
    for cx in range(x0, x1 + 1):
        land.ploughed[cx] = True

    ridges = []
    x = x0
    while x <= x1:
        rend = min(x + ridge_w - 1, x1)
        ridges.append((x, rend))
        x += period

    on_ridge = [False] * (x1 - x0 + 1)
    for rx0, rx1 in ridges:
        for cx in range(rx0, rx1 + 1):
            on_ridge[cx - x0] = True

    # Where the top of the turned loam lies in every column: the ridges
    # crowned and tapered at the shoulders, so a ridge reads as a mound
    # and not a slab with a flat lid, and the furrows at the ground.
    crown = [0] * (x1 - x0 + 1)
    for cx in range(x0, x1 + 1):
        top = land.ground(cx)
        if not on_ridge[cx - x0]:
            crown[cx - x0] = top
            continue
        run = 0
        for rx0, rx1 in ridges:
            if rx0 <= cx <= rx1:
                run = min(cx - rx0, rx1 - cx)
                break
        crown[cx - x0] = top - min(RIDGE_H, run + 1)

    for cx in range(x0, x1 + 1):
        top = land.ground(cx)
        head = crown[cx - x0]
        land.fill(cx, head, cx, top + DEPTH, LOAM)
        land.fill(cx, top - RIDGE_H, cx, head - 1, AIR)

    if fallow:
        return

    for rx0, rx1 in ridges:
        cx = rx0 + 1
        while cx <= rx1 - 1:
            if rng.chance(0.08):
                cx += 1
                continue
            # A stalk grows out of the crown and does not replace it.
            # Written over the crown cell, the ground a wizard walks was
            # the loam under one column and the loam under the stalk of
            # the next, a cell apart, which put a step in the middle of
            # a field that the field itself had not put there.
            head = crown[cx - x0]
            h = rng.between(13, 20)
            land.fill(cx, head - h, cx, head - 1, WHEAT)
            land.fill(cx - 1, head - h, cx + 1, head - h + rng.between(2, 4), WHEAT)
            cx += rng.between(2, 3)


def hedge(land, x):
    """A hedgerow: a low bank of thrown-up dirt with the hedge itself
    grown up along the top of it, the way a field boundary that has
    stood a long time looks."""
    rng = land.rng
    # The bank is a step, not a wall: the hedge on top of it is Brush
    # and he walks through that, so the only thing here that can stop
    # him is the earth it stands on.
    h = rng.between(12, 19)
    for dx in range(-2, 3):
        top = land.ground(x + dx)
        taper = min(2 - abs(dx), PLAYER_STEP - 2)
        land.fill(x + dx, top - taper, x + dx, top, DIRT)
        land.fill(x + dx, top - taper - h + abs(dx) * 3, x + dx, top - taper, GRASS)


def ditch(land, x):
    """A dry ditch cut along a field boundary, the spoil banked up on
    the field side of it."""
    # Cut to a wizard's step and no deeper, and the spoil banked no
    # higher, so a field boundary is something he crosses rather than
    # something that stops him.
    rng = land.rng
    depth = rng.between(PLAYER_STEP, PLAYER_STEP + 1)
    for dx in range(-3, 4):
        top = land.ground(x + dx)
        cut = depth - abs(dx)
        if cut > 0:
            land.fill(x + dx, top + 1, x + dx, top + cut, AIR)
    for i, dx in enumerate(range(4, 7)):
        top = land.ground(x + dx)
        land.fill(x + dx, top - min(i + 1, PLAYER_STEP), x + dx, top, DIRT)


GATE_W = 18  # wider than a wizard's body (8), so he walks straight through


def fence(land, x0, x1):
    """Posts and two rails of wood, following the ground, with a gap
    left open in the middle of the run.

    The gap is the whole reason a fence can be here at all. A rail at
    six cells is over a wizard's step, so an unbroken fence is a wall,
    and a village fenced into plots without a way through them is a
    village he cannot walk across. Every run gets a gateway."""
    rail_hi = 12
    rail_lo = 6
    span = x1 - x0
    gate_x0 = x0 + (span - GATE_W) // 2 if span > GATE_W + 8 else x1 + 1
    gate_x1 = gate_x0 + GATE_W - 1

    for x in range(x0, x1 + 1):
        if gate_x0 <= x <= gate_x1:
            continue
        top = land.ground(x)
        if (x - x0) % 22 < 2 or x == gate_x0 - 1 or x == gate_x1 + 1:
            land.fill(x, top - 15, x, top, WOOD)
        else:
            land.set(x, top - rail_hi, WOOD)
            land.set(x, top - rail_lo, WOOD)


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
        land.column(wx - 1, sill - WINDOW, sill - 1, WOOD)  # the jambs, so
        land.column(wx + WINDOW, sill - WINDOW, sill - 1, WOOD)  # it frames

    roof(land, x0, x1, top, rng)

    # A lean-to porch over the door: two wood posts and a thatched
    # pentice roof, standing out from the wall a wizard's width.
    if rng.chance(0.55):
        porch(land, door_x, floor, top)

    return door_x


def porch(land, door_x, floor, wall_top):
    """A lean-to roof over the doorway, on two posts."""
    px0, px1 = door_x - 4, door_x + DOOR_W + 3
    py = wall_top + (floor - wall_top) // 3
    land.column(px0, py, floor - 1, WOOD)
    land.column(px1, py, floor - 1, WOOD)
    land.fill(px0, py - 2, px1, py - 1, THATCH)
    land.fill(px0 - 2, py - 1, px0 - 1, py - 1, THATCH)
    land.fill(px1 + 1, py - 1, px1 + 2, py - 1, THATCH)


def dooryard(land, x0, w, door_x, lo, hi, garden_p=0.5, woodpile_p=0.5):
    """What stands around a cottage: a low garden wall with a gate
    facing the track, a stack of cut wood against the gable, and the
    ground worn to a cart track at the door. `lo`/`hi` are the plot
    span's own bounds, and nothing here reaches past them -- the same
    margin that keeps the cottage off the green keeps its yard off it
    too."""
    rng = land.rng
    x1 = x0 + w - 1

    # The cart track: gravel worn from the doorstep out to open ground.
    away = 1 if door_x - x0 > x1 - door_x else -1
    if away > 0:
        path(land, max(door_x - 2, lo), min(door_x + DOOR_W + 12, hi))
    else:
        path(land, max(door_x - 12, lo), min(door_x + DOOR_W + 1, hi))

    # A low brick garden wall closing a yard beside the house, with a
    # wood gate in it.
    if rng.chance(garden_p):
        side = 1 if rng.chance(0.5) else -1
        if side > 0:
            wx0 = min(x1 + EAVES + 3, hi - 2)
            wx1 = min(wx0 + rng.between(10, 16), hi)
        else:
            wx1 = max(x0 - EAVES - 3, lo + 2)
            wx0 = max(wx1 - rng.between(10, 16), lo)
        if wx1 > wx0:
            for x in range(wx0, wx1 + 1):
                top = land.ground(x)
                land.fill(x, top - 5, x, top, BRICK)
            gate_x = (wx0 + wx1) // 2
            gtop = land.ground(gate_x)
            land.fill(gate_x - 1, gtop - 5, gate_x + 1, gtop, AIR)
            land.column(gate_x - 2, gtop - 7, gtop, WOOD)
            land.column(gate_x + 2, gtop - 7, gtop, WOOD)

    # A woodpile against the gable end away from the door.
    if rng.chance(woodpile_p):
        wxp = max(x0 - EAVES - rng.between(4, 8), lo + 8)
        top = land.ground(wxp)
        for i in range(rng.between(3, 5)):
            land.fill(wxp - 8, top - 3 - i * 3, wxp, top - 1 - i * 3, WOOD)


def roof(land, x0, x1, eave_y, rng, gable=None, chimney_on=True):
    """A pitched thatch roof: a wood ridge beam, rafters implied by the
    slope of the thatch itself, and eaves that oversail the wall so the
    wall is in the roof's shadow. `gable` is what closes the triangle
    under the thatch -- brick over a cottage's wall, wood over a barn's
    boarding -- and a barn carries no chimney."""
    gable = gable or BRICK
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

    # The gable under the thatch closes the roof at the ends rather
    # than leaving it open to the sky.
    for x in range(x0, x1 + 1):
        t = abs(x - mid) / (span * 0.5)
        y = int(ridge_y + (eave_y - ridge_y) * t)
        land.fill(x, y + THATCH_T, x, eave_y - 1, gable)

    if chimney_on:
        chimney(land, x0, x1, ridge_y, eave_y, rng)


def chimney(land, x0, x1, ridge_y, eave_y, rng):
    cx = x0 + 6 if rng.chance(0.5) else x1 - 12
    top = ridge_y - rng.between(8, 16)
    land.fill(cx, top, cx + 6, eave_y + 4, BRICK)
    land.fill(cx + 2, top, cx + 4, top + 3, AIR)  # the flue
    land.fill(cx - 1, top, cx + 7, top + 2, BRICK)  # the cap, wider than the stack
    land.fill(cx - 1, top - 1, cx + 7, top - 1, COAL)  # soot, smoke-blackened


def barn(land, x0, w):
    """A barn: bigger than a cottage's one room, wood-framed and
    thatched over like it, but standing open across the front on posts
    so a cart can shelter under the roof -- no wall, no chimney, hay
    spilling out of it."""
    rng = land.rng
    x1 = x0 + w - 1
    floor = land.level(x0 - EAVES, x1 + EAVES)
    h = rng.between(38, 48)
    top = floor - h

    land.fill(x0, floor, x1, floor + FOOTING, ROCK)
    # The two gable ends and a head plate tying them are close-boarded
    # wood; the long front between them is left open on posts.
    land.fill(x0, top, x0 + WALL - 1, floor - 1, WOOD)
    land.fill(x1 - WALL + 1, top, x1, floor - 1, WOOD)
    land.fill(x0 + WALL, top, x1 - WALL, top + 3, WOOD)
    third = (x1 - x0) // 3
    land.column(x0 + third, top + 4, floor - 1, WOOD)
    land.column(x0 + 2 * third, top + 4, floor - 1, WOOD)
    land.fill(x0 + WALL, floor - 2, x1 - WALL, floor - 1, WOOD)  # the plank floor

    if rng.chance(0.7):
        stook(land, x0 + w // 2 + rng.between(-6, 6))

    roof(land, x0, x1, top, rng, gable=WOOD, chimney_on=False)
    return floor


# ----------------------------------------------------------- the small things


# A wizard climbs PLAYER_CLIMB (3) cells and no more, so anything
# standing higher than that on open ground is a wall to him and not a
# step. A well built to the waist -- which is what a well is built to --
# is exactly such a wall, and one standing on the green beside where he
# lands walled the road east out of the village in the first seconds of
# the game. So a well stands in a farmyard now, where a wall is what a
# building is, and its coping is low enough to step over.
WELL_COPING = 3


def well(land, x):
    """A stone well: a ring of rock standing over a shaft, with a wood
    windlass across it. The coping is a step and not a wall; what makes
    it a well rather than a ring on the grass is the hole in it."""
    top = land.level(x, x + 15)
    land.fill(x, top - WELL_COPING, x + 15, top + 2, ROCK)
    # The shaft, and the ground closed again under the bottom of it. It
    # is closed back to the strata and not to Dirt: a shaft backfilled
    # with soil is a soft column punched through the gravel and the rock
    # all the way to the floor of the region, which reads as a seam in
    # every shot pulled back and digs like one too.
    land.fill(x + 4, top - WELL_COPING, x + 11, top + WELL_DEPTH, AIR)
    for y in range(top + WELL_DEPTH + 1, IMG):
        land.fill(x + 4, y, x + 11, y, stratum_at(y))
    # A few stones and flecks through the backfill, so the closed shaft
    # does not show as a clean stripe against the flecked ground around
    # it -- it was dug and filled, not cast in one piece.
    rng = land.rng
    for _ in range(6):
        fx = rng.between(x + 4, x + 11)
        fy = rng.between(top + WELL_DEPTH + 8, IMG - 6)
        blob(land, fx, fy, rng.between(1, 2), ROCK if rng.chance(0.6) else DIRT)
    # The frame stands clear over his head, so he walks under it rather
    # than into it: the posts start above a wizard's hat and the beam is
    # higher still.
    land.fill(x + 1, top - 34, x + 2, top - 18, WOOD)  # the posts
    land.fill(x + 13, top - 34, x + 14, top - 18, WOOD)
    land.fill(x + 1, top - 36, x + 14, top - 35, WOOD)  # the beam
    land.fill(x + 6, top - 34, x + 9, top - 32, WOOD)  # the windlass


def stook(land, x):
    """A stook of cut wheat, leaned together and standing in the field."""
    top = land.ground(x)
    for i, dx in enumerate((-3, -1, 1, 3)):
        lean = (i - 1.5) * 0.9
        # From one cell over the ground up. Standing growth grows out of
        # the ground and does not replace it: written into the cell it
        # stands on, a stook took the ground out from under itself --
        # Wheat is `state = Brush`, which a wizard walks through, so what
        # he then walked on was the loam a cell lower, and a stook put a
        # step in the middle of a field that the field had not.
        for k in range(1, 15):
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


# Twelve stretches of one village, not twelve shuffles of the same
# stretch: how eagerly plots cluster into a village knot (cluster_p),
# how big a knot runs (sizes), how often its first building is a barn
# rather than a home (barn_p), how much of the tilled ground stands
# fallow, hedged with a tree instead of a hedge (orchard_p), walled
# into a garden (garden_p), and how wide one field is let run.
THEMES = [
    dict(cluster_p=0.12, sizes=[1],    barn_p=0.0,  fallow_p=0.65, orchard_p=0.08, garden_p=0.30, field_max=70),  # pasture
    dict(cluster_p=0.85, sizes=[2, 3], barn_p=0.35, fallow_p=0.15, orchard_p=0.05, garden_p=0.55, field_max=48),  # village
    dict(cluster_p=0.10, sizes=[1],    barn_p=0.0,  fallow_p=0.05, orchard_p=0.00, garden_p=0.10, field_max=120),  # wheat
    dict(cluster_p=0.55, sizes=[2],    barn_p=0.80, fallow_p=0.30, orchard_p=0.05, garden_p=0.30, field_max=70),  # barnyard
    dict(cluster_p=0.25, sizes=[1, 2], barn_p=0.10, fallow_p=0.35, orchard_p=0.55, garden_p=0.20, field_max=50),  # orchard
    dict(cluster_p=0.35, sizes=[1, 2], barn_p=0.10, fallow_p=0.20, orchard_p=0.10, garden_p=0.75, field_max=60),  # garden
    dict(cluster_p=0.45, sizes=[1, 2], barn_p=0.30, fallow_p=0.28, orchard_p=0.15, garden_p=0.40, field_max=75),  # mixed
    dict(cluster_p=0.28, sizes=[1],    barn_p=0.05, fallow_p=0.20, orchard_p=0.10, garden_p=0.20, field_max=42),  # hedgerow
    dict(cluster_p=0.18, sizes=[1],    barn_p=0.0,  fallow_p=0.80, orchard_p=0.05, garden_p=0.15, field_max=90),  # fallow
    dict(cluster_p=0.90, sizes=[2],    barn_p=0.15, fallow_p=0.20, orchard_p=0.10, garden_p=0.60, field_max=55),  # cluster
    dict(cluster_p=0.08, sizes=[1],    barn_p=0.0,  fallow_p=0.00, orchard_p=0.00, garden_p=0.10, field_max=140),  # harvest
    dict(cluster_p=0.40, sizes=[1, 2], barn_p=0.25, fallow_p=0.25, orchard_p=0.30, garden_p=0.35, field_max=65),  # mixed2
]


def span_of(rng, x0, x1, theme):
    """Fill one span with plots, end to end. Buildings come in a knot
    of one to three, close together with a yard between them, and then
    open field runs before the next knot -- a village clusters, it does
    not scatter one thing, gap, one thing, gap."""
    out = []
    x = x0 + rng.between(2, 12)
    while x1 - x > 34:
        room = x1 - x
        if room > 90 and rng.chance(theme["cluster_p"]):
            n = rng.pick(theme["sizes"])
            for k in range(n):
                room = x1 - x
                if room < 40:
                    break
                if k == 0 and rng.chance(theme["barn_p"]):
                    w = rng.between(70, min(94, room - 4))
                    out.append((x, w, "barn"))
                else:
                    w = rng.between(56, min(84, room - 4))
                    out.append((x, w, "home"))
                x += w + rng.between(3, 9)  # tight: a knot, not a scatter
            x += rng.between(22, 52)  # open ground before the next knot
        else:
            w = rng.between(34, min(theme["field_max"], max(35, room - 2)))
            out.append((x, w, "field"))
            x += w + rng.between(8, 18)
    return out


# A cottage oversails its own footprint by the eaves, and a fence run
# reaches past the plot it closes, so a plot span stops short of the
# green by this much.
MARGIN = EAVES + 4


def plots(rng, theme):
    """The row of plots across one picture, west of the green and east
    of it, each with the span it may not reach out of."""
    west = (EDGE + 2, GREEN_X0 - 1 - MARGIN)
    east = (GREEN_X1 + 1 + MARGIN, IMG - EDGE - 3)
    return [
        (west, span_of(rng, west[0], west[1], theme)),
        (east, span_of(rng, east[0], east[1], theme)),
    ]


def paint_homeland(seed, i=0):
    land = Land(seed)
    theme = THEMES[i % len(THEMES)]
    lay_ground(land)

    # The plots are drawn from a stream of their own, apart from the
    # ground's: a plot's layout is a stylistic choice, not a physical
    # one, and keeping it off the ground's stream means a change here
    # never reaches back to perturb the soil, the strata or the green.
    rng = Rng(seed ^ PLOT_SALT)
    land.rng = rng

    # West to east within each span, so a plot settles against ground
    # that is already drawn: `plough` clamps its west end to whatever
    # stands beside it, and out of order there is nothing there to clamp
    # to. Knots put them out of order.
    for (lo, hi), row in plots(rng, theme):
        for x, w, kind in sorted(row):
            if kind == "home":
                door_x = cottage(land, x, w)
                dooryard(land, x, w, door_x, lo, hi, garden_p=theme["garden_p"])
                if rng.chance(0.5):
                    fence(land, min(x + w + EAVES + 2, hi), min(x + w + EAVES + 22, hi))
                # The well belongs to a farmyard, not to the green: on
                # the green it stood in the road out of the village.
                if rng.chance(0.4) and x + w + EAVES + 26 < hi - 16:
                    well(land, x + w + EAVES + 26)
            elif kind == "barn":
                barn(land, x, w)
                if rng.chance(0.6):
                    fence(land, min(x + w + EAVES + 2, hi), min(x + w + EAVES + 20, hi))
            else:
                plough(land, x, x + w - 1, fallow=rng.chance(theme["fallow_p"]))
                # A field is hedged, ditched, treed or fenced at both
                # ends, so it reads as a bounded plot and not tilled
                # ground running loose into whatever is next to it.
                for end_x in (max(x - 3, lo), min(x + w + 2, hi)):
                    if rng.chance(theme["orchard_p"]):
                        tree(land, end_x)
                    elif rng.chance(0.42):
                        hedge(land, end_x)
                    elif rng.chance(0.3):
                        ditch(land, end_x)
                    else:
                        fence(land, end_x - 1, end_x + 1)
                if rng.chance(0.45):
                    stook(land, x + rng.between(6, max(7, w - 6)))

    # The green: a gravel track worn the length of it, and off the track
    # a fence line, a well or a tree, but never in the yard he lands in.
    # Drawn off a stream of its own, keyed only to the picture's seed,
    # so nothing about how the fields or cottages roll their dice ever
    # moves what stands on the green.
    green_rng = Rng(seed ^ GREEN_SALT)
    land.rng = green_rng
    path(land, GREEN_X0 + 2, GREEN_X1 - 2)
    if green_rng.chance(0.7):
        fence(land, 206, YARD_X0 - 6)  # between the track's west reach and the yard
    if green_rng.chance(0.5):
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


TIMBER_CORBEL = 8  # how far a shoring post hangs below its roof beam


def timber_frame(land, cx, y_top, half_w):
    """Shoring in a worked tunnel, seen from the side: a beam under the
    roof and a short post down each end of it.

    The posts hang from the beam and never reach the floor. A timber
    set really does stand floor to roof, but a side elevation of one
    that did would be a solid wall across the only way in -- the
    passage is the thing the picture is about, so the timber reads
    against the roof and the way through stays open."""
    land.fill(cx - half_w, y_top, cx + half_w, y_top + 2, WOOD)
    for px in (cx - half_w, cx + half_w):
        land.fill(px, y_top, px + 1, y_top + TIMBER_CORBEL, WOOD)


def cart_rail(land, x0, x1, floor_y, floor_from):
    """A cart rail worn out of the mouth: a gravel bed with a wood
    sleeper set across it every few cells. It lies on the field until
    it reaches the mouth and on the floor of the adit past that, so it
    is one track and not two."""
    for x in range(x0, x1 + 1):
        top = floor_y if x >= floor_from else land.ground(x)
        land.set(x, top, GRAVEL)
        if (x - x0) % 5 == 0:
            land.set(x, top - 1, WOOD)


def spoil_heap(land, cx, rng):
    """A heap of spoil dumped outside the mouth by whoever dug it:
    gravel and a fleck of coal, banked up in courses."""
    top = land.ground(cx)
    for i in range(4):
        w = max(2, rng.between(12, 20) - i * 4)
        h = 4 - min(i, 3)
        land.fill(cx - w // 2, top - i * 3 - h, cx + w // 2, top - i * 3, GRAVEL)
    for _ in range(8):
        px = cx + rng.between(-9, 9)
        py = top - rng.between(1, 9)
        land.set(px, py, COAL)


def paint_cavemouth():
    """Where the fields end.

    The last headland runs east into a hillside that climbs the whole
    height of the region, so at the east edge the ground stands at the
    top of the picture -- which is exactly where the Coalmine region
    beside it starts, and the two meet with no step. A mouth opens in
    the lower face of that hillside at the height a wizard walks in
    at: worked and squared for the first stretch behind it, and only
    past that does the passage turn natural and wind down into the
    coal."""
    land = Land(0xCA7E)
    rng = land.rng
    lay_ground(land)  # ordinary field strata everywhere first, so the
                       # gravel band and the rock roof are already there
                       # to run into the bluff rather than be replaced

    # The hillside's skyline: a scarp FACE cells high at the foot of
    # it, broken by broad shoulders and a jagged, finer edge rather
    # than one ruled slope, climbing on to the top of the region where
    # the coal begins.
    roll = smooth_field(rng, IMG, 60, 6)
    scarp = smooth_field(rng, IMG, 21, 9)
    jag = smooth_field(rng, IMG, 7, 5.0)
    crag = smooth_field(rng, IMG, 4, 3.0)
    ledge = smooth_field(rng, IMG, 34, 11)
    crest = [EDGE_GROUND] * IMG
    for x in range(BLUFF_X0, IMG):
        t = (x - BLUFF_X0) / (IMG - 1 - BLUFF_X0)
        foot = EDGE_GROUND - FACE
        climb = t ** 0.6
        broken = max(0.0, 1.0 - t * 1.3)
        shoulder = max(0.0, 1.0 - t * 2.4)
        c = int(
            foot * (1.0 - climb)
            + roll[x] * (1.0 - abs(2 * t - 1))
            + scarp[x] * (1.0 - t)
            + jag[x] * broken
            + crag[x] * broken
            + ledge[x] * shoulder
        )
        crest[x] = max(0, min(EDGE_GROUND, c))
        land.fill(x, 0, x, crest[x] - 1, AIR)
        # Soil and grass hold on the lower slope and give out further up.
        if t < 0.42:
            land.fill(x, crest[x] - SKIN, x, crest[x] - 1, GRASS)
            land.fill(x, crest[x], x, crest[x] + int((0.42 - t) * 40), DIRT)
        land.top[x] = crest[x]

    # The rock does not meet the fields' own strata in a ruled plane:
    # for a short buffer past the face the ground is exactly what a
    # field's is -- the gravel band and the rock roof both still there,
    # wandering as they do everywhere else -- and only past that does
    # the hill's own body start rising up through them, thinning the
    # dirt above it until, well inside the hill, there is nothing left
    # over the surface but rock.
    belly_wander = smooth_field(rng, IMG, 55, 50)
    belly_fine = smooth_field(rng, IMG, 17, 22)
    for x in range(BLUFF_X0, IMG):
        t = (x - BLUFF_X0) / (IMG - 1 - BLUFF_X0)
        skin_bottom = crest[x] + (int((0.42 - t) * 40) if t < 0.42 else 0)
        settle = 0.0 if t < 0.06 else min(1.0, (t - 0.06) / 0.5)
        rock_top = int(
            IMG * (1.0 - settle) + skin_bottom * settle
            + belly_wander[x] * settle + belly_fine[x] * 0.6
        )
        rock_top = max(skin_bottom, min(IMG - 1, rock_top))

        # First the ordinary strata, exactly as a field would have them
        # at these depths -- this is what makes the gravel band and the
        # rock roof carry on into the bluff -- because the ground here
        # used to be flat and lower, and simply had not been repainted
        # for the new, higher crest: left alone, the old flat skin
        # would hang in the air where the hill now stands over it.
        # Then the hill's own body overrides the top of that from
        # rock_top down, so what is left above it is soil and what is
        # below reads as the same rock whether it is the hill's or the
        # roof of the mine.
        for y in range(skin_bottom, IMG):
            land.cells[y][x] = stratum_at_col(land, x, y)
        land.fill(x, rock_top, x, IMG - 1, ROCK)

    # A few tongues of the same rock reach west, up into the subsoil
    # above where the main mass starts, so the boundary is a handful of
    # fingers advancing at different rates and not a wall.
    for _ in range(10):
        cx = BLUFF_X0 - int(rng.unit() ** 2 * BLUFF_BLEND)
        cy = rng.between(EDGE_GROUND - 10, GRAVEL_TOP - 15)
        blob(land, cx, cy, rng.between(10, 22), ROCK, flat=rng.between(2, 4))

    # Texture on the exposed face itself, not just its skyline: lenses
    # of gravel breaking up what would otherwise be a flat grey wall.
    for _ in range(30):
        cx = rng.between(BLUFF_X0 + 4, BLUFF_X0 + 260)
        cy = rng.between(EDGE_GROUND - FACE - 10, EDGE_GROUND + 120)
        if land.at(cx, cy) == ROCK:
            blob(land, cx, cy, rng.between(4, 10), GRAVEL, flat=rng.between(1, 3))

    # A broken shoulder: an overhang where the rock juts out over a
    # notch undercut into the face beneath it, so the face reads as
    # broken rock and not one ruled slope throughout.
    for _ in range(3):
        ox = rng.between(BLUFF_X0 + 24, BLUFF_X0 + 210)
        oy = crest[ox] + rng.between(16, 30)
        ow = rng.between(26, 42)
        oh = rng.between(7, 12)
        land.fill(ox - ow // 2, oy, ox + ow // 2, oy + oh, AIR)

    # Scree at the foot of the face: loose rock that has come off it,
    # banked against the scarp. It banks west of the mouth and not over
    # it -- inside the hill `land.ground` is the crest, a hundred cells
    # up, and a heap piled there is a heap on the hilltop.
    for x in range(ADIT_X0 - 74, ADIT_X0 - 6):
        t2 = (ADIT_X0 - 6 - x) / 68
        pile = max(0, int(18 * t2 ** 1.5 * (0.5 + 0.5 * rng.unit())))
        top = land.ground(x)
        land.fill(x, top - pile, x, top, GRAVEL)

    # The mouth: for the first ADIT_LEN cells behind it the passage is
    # worked, not natural -- a squared adit, flat floored and straight
    # roofed at the height the timber lintels sit, propped at
    # intervals. Only past that does it widen into the round, natural
    # passage the same way it always has.
    adit_x0 = ADIT_X0
    adit_x1 = adit_x0 + ADIT_LEN
    adit_mid_y = EDGE_GROUND - 17
    adit_roof = adit_mid_y - ADIT_HALF_H
    adit_floor = adit_mid_y + ADIT_HALF_H
    land.fill(adit_x0, adit_roof, adit_x1, adit_floor, AIR)
    for px in range(adit_x0 + ADIT_HALF_W, adit_x1 - ADIT_HALF_W, 22):
        timber_frame(land, px, adit_roof, ADIT_HALF_W - 2)

    mouth_run = (
        (adit_x1, adit_mid_y, ADIT_HALF_W),
        (BLUFF_X0 + 116, EDGE_GROUND + 40, 27),
        (BLUFF_X0 + 168, EDGE_GROUND + 150, 34),
        (BLUFF_X0 + 196, IMG - 96, 42),
    )
    carve_run(land, mouth_run)

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
    for x in range(ADIT_X0 - 44, adit_x1):
        for y in range(adit_roof, IMG):
            if land.at(x, y) in (ROCK, DIRT, GRASS):
                land.fill(x, y, x, y + 2, GRAVEL)
                break

    # A cart rail and a heap of spoil outside where the diggings came out.
    cart_rail(land, ADIT_X0 - 60, adit_x1 - 4, adit_floor, ADIT_X0)
    spoil_heap(land, ADIT_X0 - 44, rng)

    # Coal in the rock, so the reason to go down is visible from inside
    # the mouth: bedded seams, not round holes punched in it.
    for _ in range(26):
        cx = rng.between(BLUFF_X0, IMG - 20)
        cy = rng.between(20, IMG - 20)
        if land.at(cx, cy) == ROCK:
            coal_seam(land, cx, cy, rng)

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

    faults += check_walkable(path_name, grid)

    for x0, x1, what in ((YARD_X0, YARD_X1, "the yard"),):
        for x in range(x0, x1 + 1):
            for y in range(IMG):
                if grid[y][x] not in PLAIN:
                    faults.append(
                        f"{path_name}: {grid[y][x]} at {x},{y} is in {what}"
                        f" ({x0}..{x1}), which must be plain pasture"
                    )
                    break
    return faults


def check_walkable(path_name, grid):
    """The worked ground of a homeland must be ground a wizard can walk.

    He steps up PLAYER_STEP cells and no more. A ridge, a furrow, a
    hedge bank, a ditch and the coping of a well are all things he
    should walk over without thinking about it, so none of them may
    make a step higher than that. What he built -- a wall, a roof, a
    fence, a stack of cut wood -- may stop him, because he jumps.

    This is the rule the first draft broke everywhere at once: furrows
    four cells under ridges four cells proud, every dozen cells, the
    length of every field. Holding one key walked him forty cells and
    then nothing."""
    faults = []

    def surface(x):
        for y in range(IMG):
            if grid[y][x] not in WALKED_THROUGH:
                return y
        return IMG

    prev = surface(EDGE)
    for x in range(EDGE + 1, IMG - EDGE):
        here = surface(x)
        rise = prev - here
        if rise > PLAYER_STEP and here < IMG and grid[here][x] in GROUND:
            faults.append(
                f"{path_name}: the ground at {x} stands {rise} cells over the ground beside it"
                f" ({grid[here][x]}), and a wizard steps up {PLAYER_STEP}"
            )
        prev = here
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
    stack = [(0, EDGE_GROUND - SKIN - 1)]
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
        land = paint_homeland(0x480E + i * 7919, i)
        museum.write_png(name, museum.render(land, materials))
        print(f"{name}: {IMG}x{IMG}")

    museum.write_png(MOUTH_PATH, museum.render(paint_cavemouth(), materials))
    print(f"{MOUTH_PATH}: {IMG}x{IMG}")


if __name__ == "__main__":
    main()
