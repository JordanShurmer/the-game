package game

import "core:fmt"
import "core:testing"

/*
Wang tiles.

A biome no longer draws one tile. It draws a whole set, and the world
picks which tile of that set covers each square of the tile lattice.
The pick has to look random and still leave no seam where two tiles
meet. That is what a Wang tile set is for.

Every edge of the lattice carries a color. A tile carries four of
them, one per side, and a tile may only sit where its four colors
match the four edges around it. Neighbours therefore always agree on
the edge they share, whichever way the world picked them.

The lattice edges are colored by a hash of their own position, not by
a scan across the world. That is the whole reason this works here: a
rectangle of world still generates alone, in any order, with no
neighbour to ask. Two calls that overlap read the same edge colors,
so they draw the same tiles.

With WANG_COLORS colors a set is complete when it holds one tile for
every combination of four edges, which is WANG_SIGNATURES tiles. The
loader gives a biome exactly that many, times its variant count, so
the lookup never has to handle a hole.

Matching colors is only half of a seam. The cells beside the edge have
to line up as well, or a tunnel would stop dead at the border of a
tile. So the WANG_SEAM cells along each side belong to the edge color
rather than to the tile: every tile that carries color c on its west
side holds the same WANG_SEAM columns there. The editor keeps that
true as you paint, and the save gate refuses a set where it is not.

The corners are the price of the simple rule. A corner cell sits in
two bands at once, one for each side it touches, and the two bands
reach different groups of tiles. Holding both true at once makes the
corner common to the whole set. WANG_SEAM stays small so those shared
squares are a few cells of plain fill and no eye can find the grid in
them.
*/

// Colors one lattice edge can carry. Two is the bottom rung: a
// complete set is 16 tiles, which one person can draw. Four colors
// would need 256, so climb only when a biome earns it.
WANG_COLORS :: 2
WANG_BITS :: 1 // bits one edge color takes in a signature

#assert(1 << WANG_BITS == WANG_COLORS)

// One tile per combination of four edges.
WANG_SIGNATURES :: WANG_COLORS * WANG_COLORS * WANG_COLORS * WANG_COLORS

// Cells along each side that belong to the edge color instead of to
// the tile. Wide enough to carry a tunnel mouth through the border,
// narrow enough that the shared corners stay invisible.
//
// A corner is the one place the scheme cannot make continuous: it
// belongs to two bands at once, so the whole set has to hold it, and
// whatever is drawn there agrees with neither band. That square is
// WANG_SEAM on a side, so this is kept small for the same reason it
// always was: 4 of 256 leaves a square no eye finds, and the crossfade
// in the seeder carries the rest of the way across a border.
WANG_SEAM :: 4

#assert(WANG_SEAM > 0 && WANG_SEAM * 2 < TILE_SIZE, "the two seams of an axis must not meet")

/*
The four edge colors of a tile, packed low to high: north, east,
south, west. Clockwise from the top, the way a compass reads.

A signature is also the index of the tile inside its set, so the set
needs no lookup table: the tile for a signature is at a known offset
from the first tile of the biome.
*/
Wang_Signature :: u8

wang_signature :: proc(n, e, s, w: u8) -> Wang_Signature {
	return Wang_Signature(
		u32(n) | u32(e) << u32(WANG_BITS) | u32(s) << u32(2 * WANG_BITS) | u32(w) << u32(3 * WANG_BITS),
	)
}

wang_north :: proc(sig: Wang_Signature) -> u8 {return u8(u32(sig) & (WANG_COLORS - 1))}
wang_east :: proc(sig: Wang_Signature) -> u8 {return u8((u32(sig) >> u32(WANG_BITS)) & (WANG_COLORS - 1))}
wang_south :: proc(sig: Wang_Signature) -> u8 {return u8((u32(sig) >> u32(2 * WANG_BITS)) & (WANG_COLORS - 1))}
wang_west :: proc(sig: Wang_Signature) -> u8 {return u8((u32(sig) >> u32(3 * WANG_BITS)) & (WANG_COLORS - 1))}

// ------------------------------------------------------------
// The lattice
// ------------------------------------------------------------

/*
The hash behind every choice the lattice makes.

It is splitmix64 run twice, once after x and once after y, so the two
coordinates cannot cancel each other out. A plain xor of two products
would give the same answer for (3,5) and (5,3) under some constants,
and a world with a diagonal mirror in it would be the result.

The salt separates the questions asked at one position: the color of
the edge above a square is not the color of the edge to its left.
*/
@(private = "file")
wang_mix :: proc(v: u64) -> u64 {
	h := v
	h ~= h >> 30
	h *= 0xBF58476D1CE4E5B9
	h ~= h >> 27
	h *= 0x94D049BB133111EB
	h ~= h >> 31
	return h
}

wang_hash :: proc(seed, salt: u64, x, y: i32) -> u64 {
	h := seed ~ salt * 0x9E3779B97F4A7C15
	h ~= u64(u32(x)) * 0xD6E8FEB86659FD93
	h = wang_mix(h)
	h ~= u64(u32(y)) * 0xA3B195354A39B70D
	return wang_mix(h)
}

// One salt per question. The values are arbitrary and only have to
// differ from each other.
WANG_SALT_HORIZONTAL :: 0x0000_0000_0000_0001
WANG_SALT_VERTICAL :: 0x0000_0000_0000_0002
WANG_SALT_VARIANT :: 0x0000_0000_0000_0003

/*
The color of a lattice edge.

A horizontal edge (hx,hy) runs along the top of the lattice square
(hx,hy), which is also the bottom of the square above it. A vertical
edge (vx,vy) runs down the left of square (vx,vy), which is the right
of the square to its left. Two neighbours therefore ask for one edge
by one name and always get one answer.
*/
wang_horizontal_edge :: proc(seed: u64, hx, hy: i32) -> u8 {
	return u8(wang_hash(seed, WANG_SALT_HORIZONTAL, hx, hy) & (WANG_COLORS - 1))
}

wang_vertical_edge :: proc(seed: u64, vx, vy: i32) -> u8 {
	return u8(wang_hash(seed, WANG_SALT_VERTICAL, vx, vy) & (WANG_COLORS - 1))
}

// The four edges around one lattice square, as a signature.
wang_signature_at :: proc(seed: u64, sx, sy: i32) -> Wang_Signature {
	n := wang_horizontal_edge(seed, sx, sy)
	s := wang_horizontal_edge(seed, sx, sy + 1)
	w := wang_vertical_edge(seed, sx, sy)
	e := wang_vertical_edge(seed, sx + 1, sy)
	return wang_signature(n, e, s, w)
}

/*
The tile of a set that covers one lattice square.

The signature says which tiles may sit here. The variants of that
signature all carry the same four edges, so any of them fits, and a
second hash picks one. That is the free choice the author asked for:
the seams stay locked and the middle of the tile changes.
*/
wang_tile_at :: proc(seed: u64, b: Biome, sx, sy: i32) -> Tile_Id {
	sig := wang_signature_at(seed, sx, sy)
	variant := 0
	if b.variants > 1 {
		variant = int(wang_hash(seed, WANG_SALT_VARIANT, sx, sy) % u64(b.variants))
	}
	return wang_tile_id(b, sig, variant)
}

// Where one tile of a set sits in the Tile_Set. Variants of a
// signature are next to each other, so a set reads in signature order.
wang_tile_id :: proc(b: Biome, sig: Wang_Signature, variant: int) -> Tile_Id {
	return b.tile_base + Tile_Id(int(sig) * int(b.variants) + variant)
}

// Variants of one signature. More than a handful is authoring nobody
// finishes, and the set size climbs with it.
WANG_MAX_VARIANTS :: 8

/*
The file one tile lives in.

The name carries the constraint: the four digits are the edge colors,
north east south west, and the last number says which variant of them
this is. Two files that must agree along a side say so in their names,
so an author working in a pixel editor can see the rule without
reading the code.

The string comes from the temporary allocator. Every caller uses it
inside one frame or one tool call and drops it.
*/
wang_tile_path :: proc(prefix: string, sig: Wang_Signature, variant: int) -> string {
	return fmt.tprintf(
		"%s_%d%d%d%d_%d.png",
		prefix,
		wang_north(sig),
		wang_east(sig),
		wang_south(sig),
		wang_west(sig),
		variant,
	)
}

// How many tiles a biome owns: one per signature, times the variants.
wang_set_size :: proc(b: Biome) -> int {
	if b.tile_base == TILE_NONE do return 0
	return WANG_SIGNATURES * int(b.variants)
}

// The signature of a tile, from where it sits in the set.
wang_signature_of :: proc(b: Biome, tile: Tile_Id) -> Wang_Signature {
	return Wang_Signature((int(tile) - int(b.tile_base)) / int(b.variants))
}

wang_variant_of :: proc(b: Biome, tile: Tile_Id) -> int {
	return (int(tile) - int(b.tile_base)) % int(b.variants)
}

// ------------------------------------------------------------
// The seams
// ------------------------------------------------------------

/*
Which part of a tile a cell belongs to.

Inside is the free middle. A side band belongs to the edge color of
that side, so every tile with that color holds the same cells there.
A corner belongs to two sides at once, so the whole set holds it.
*/
Wang_Band :: enum u8 {
	Inside,
	North,
	East,
	South,
	West,
	Corner,
}

wang_band :: proc(x, y: i32) -> Wang_Band {
	across := Wang_Band.Inside
	if x < WANG_SEAM {
		across = .West
	} else if x >= TILE_SIZE - WANG_SEAM {
		across = .East
	}

	down := Wang_Band.Inside
	if y < WANG_SEAM {
		down = .North
	} else if y >= TILE_SIZE - WANG_SEAM {
		down = .South
	}

	if across != .Inside && down != .Inside do return .Corner
	if across != .Inside do return across
	return down
}

// The color a tile carries on the side a band belongs to. A corner
// belongs to no single side, so every tile answers alike and the
// whole set shares the cell.
wang_band_color :: proc(sig: Wang_Signature, band: Wang_Band) -> u8 {
	switch band {
	case .North:
		return wang_north(sig)
	case .East:
		return wang_east(sig)
	case .South:
		return wang_south(sig)
	case .West:
		return wang_west(sig)
	case .Corner:
		return 0
	case .Inside:
		return 0
	}
	return 0
}

// Do two tiles of one set hold this cell in common?
wang_shares_cell :: proc(a, b: Wang_Signature, x, y: i32) -> bool {
	band := wang_band(x, y)
	if band == .Inside do return false
	return wang_band_color(a, band) == wang_band_color(b, band)
}

/*
Write one cell into every tile that shares it.

This is the constraint the editor paints through. A stroke in the
middle of a tile touches that tile alone. A stroke in a band reaches
every tile with the same color on that side, so the seam it draws is
the seam the world shows wherever that edge color turns up.
*/
wang_paint_cell :: proc(set: Tile_Set, b: Biome, sig: Wang_Signature, x, y: i32, c: Cell) {
	band := wang_band(x, y)
	if band == .Inside do return

	for other in 0 ..< WANG_SIGNATURES {
		if wang_band_color(Wang_Signature(other), band) != wang_band_color(sig, band) do continue
		for v in 0 ..< int(b.variants) {
			tile_set_cell(set, wang_tile_id(b, Wang_Signature(other), v), x, y, c)
		}
	}
}

/*
Where a set disagrees with itself.

Two tiles that share a cell must hold the same material in it. The
editor keeps that true, so a conflict means a tile file was painted
somewhere else. The save gate reports the first one it finds, because
one clear place to look beats a count.
*/
Wang_Conflict :: struct {
	a:     Tile_Id, // the two tiles that disagree
	b:     Tile_Id,
	x:     i32,     // the cell they disagree about
	y:     i32,
	found: bool,
}

wang_find_conflict :: proc(set: Tile_Set, b: Biome) -> Wang_Conflict {
	count := wang_set_size(b)
	if count == 0 do return {}

	for y in i32(0) ..< TILE_SIZE {
		for x in i32(0) ..< TILE_SIZE {
			band := wang_band(x, y)
			if band == .Inside do continue

			// The first tile of a color speaks for the rest of it.
			leader: [WANG_COLORS]Tile_Id
			has_leader: [WANG_COLORS]bool

			for i in 0 ..< count {
				tile := b.tile_base + Tile_Id(i)
				color := wang_band_color(wang_signature_of(b, tile), band)

				if !has_leader[color] {
					has_leader[color] = true
					leader[color] = tile
					continue
				}
				if tile_at(set, leader[color], x, y) != tile_at(set, tile, x, y) {
					return {a = leader[color], b = tile, x = x, y = y, found = true}
				}
			}
		}
	}
	return {}
}

/*
Make a set agree with itself again.

For every shared cell the first tile that holds it wins, and the rest
of its group takes that value. It is the one repair that needs no
choice from the author, and it leaves the middle of every tile alone.
*/
wang_normalize :: proc(set: Tile_Set, b: Biome) -> (changed: int) {
	count := wang_set_size(b)
	if count == 0 do return 0

	for y in i32(0) ..< TILE_SIZE {
		for x in i32(0) ..< TILE_SIZE {
			band := wang_band(x, y)
			if band == .Inside do continue

			leader: [WANG_COLORS]Tile_Id
			has_leader: [WANG_COLORS]bool

			for i in 0 ..< count {
				tile := b.tile_base + Tile_Id(i)
				color := wang_band_color(wang_signature_of(b, tile), band)

				if !has_leader[color] {
					has_leader[color] = true
					leader[color] = tile
					continue
				}
				want := tile_at(set, leader[color], x, y)
				if tile_at(set, tile, x, y) != want {
					tile_set_cell(set, tile, x, y, want)
					changed += 1
				}
			}
		}
	}
	return changed
}

// ------------------------------------------------------------
// Tests
// ------------------------------------------------------------

@(private = "file")
make_test_set :: proc(variants: u8) -> (b: Biome, set: Tile_Set) {
	b = Biome {
		generator = .Wang,
		tile_base = 0,
		variants  = variants,
	}
	set = make_tile_set(wang_set_size(b))
	return b, set
}

@(test)
test_wang_signature_packs_four_edges :: proc(t: ^testing.T) {
	seen: [WANG_SIGNATURES]bool

	for n in u8(0) ..< WANG_COLORS {
		for e in u8(0) ..< WANG_COLORS {
			for s in u8(0) ..< WANG_COLORS {
				for w in u8(0) ..< WANG_COLORS {
					sig := wang_signature(n, e, s, w)
					testing.expectf(t, int(sig) < WANG_SIGNATURES, "signature %d is out of the set", sig)
					testing.expect(t, !seen[sig], "two edge sets must not share a signature")
					seen[sig] = true

					testing.expect(t, wang_north(sig) == n)
					testing.expect(t, wang_east(sig) == e)
					testing.expect(t, wang_south(sig) == s)
					testing.expect(t, wang_west(sig) == w)
				}
			}
		}
	}

	for used in seen do testing.expect(t, used, "the set must cover every combination of edges")
}

/*
The reason the whole scheme works: two squares beside each other read
one edge, so the tiles that land on them always agree about it. The
world never asks a neighbour, and still nothing is out of step.
*/
@(test)
test_wang_lattice_neighbours_agree :: proc(t: ^testing.T) {
	seed := u64(0xC0FFEE)

	for sy in i32(-40) ..< i32(40) {
		for sx in i32(-40) ..< i32(40) {
			here := wang_signature_at(seed, sx, sy)
			right := wang_signature_at(seed, sx + 1, sy)
			below := wang_signature_at(seed, sx, sy + 1)

			testing.expectf(
				t,
				wang_east(here) == wang_west(right),
				"the shared edge at %d,%d must have one color",
				sx,
				sy,
			)
			testing.expectf(
				t,
				wang_south(here) == wang_north(below),
				"the shared edge under %d,%d must have one color",
				sx,
				sy,
			)
		}
	}
}

@(test)
test_wang_lattice_uses_every_color_and_follows_the_seed :: proc(t: ^testing.T) {
	counts: [WANG_COLORS]int
	differences := 0

	for sy in i32(0) ..< i32(64) {
		for sx in i32(0) ..< i32(64) {
			counts[wang_horizontal_edge(1, sx, sy)] += 1
			if wang_signature_at(1, sx, sy) != wang_signature_at(2, sx, sy) do differences += 1
		}
	}

	total := 64 * 64
	for c, i in counts {
		testing.expectf(
			t,
			c > total / 4 && c < total * 3 / 4,
			"color %d covers %d of %d edges, which is not a fair share",
			i,
			c,
			total,
		)
	}

	testing.expect(t, differences > total / 2, "another seed must lay out another world")
}

@(test)
test_wang_band_splits_the_tile :: proc(t: ^testing.T) {
	testing.expect(t, wang_band(0, 0) == .Corner)
	testing.expect(t, wang_band(TILE_SIZE - 1, 0) == .Corner)
	testing.expect(t, wang_band(0, TILE_SIZE - 1) == .Corner)
	testing.expect(t, wang_band(TILE_SIZE - 1, TILE_SIZE - 1) == .Corner)

	testing.expect(t, wang_band(0, TILE_SIZE / 2) == .West)
	testing.expect(t, wang_band(TILE_SIZE - 1, TILE_SIZE / 2) == .East)
	testing.expect(t, wang_band(TILE_SIZE / 2, 0) == .North)
	testing.expect(t, wang_band(TILE_SIZE / 2, TILE_SIZE - 1) == .South)

	testing.expect(t, wang_band(TILE_SIZE / 2, TILE_SIZE / 2) == .Inside)
	testing.expect(t, wang_band(WANG_SEAM, WANG_SEAM) == .Inside, "the bands stop where the middle starts")
}

/*
A cell in a band belongs to one edge color, so it reaches the tiles
that carry that color and stops at the rest. A cell in the middle
belongs to its own tile alone.
*/
@(test)
test_wang_paint_reaches_the_edge_color_and_no_further :: proc(t: ^testing.T) {
	b, set := make_test_set(2)
	defer destroy_tile_set(set)

	for i in 0 ..< wang_set_size(b) do tile_fill(set, Tile_Id(i), 0)

	// A cell on the west side of a tile whose west edge is color 1.
	source := wang_signature(0, 0, 0, 1)
	x, y := i32(1), i32(TILE_SIZE / 2)
	testing.expect(t, wang_band(x, y) == .West)

	wang_paint_cell(set, b, source, x, y, 7)

	for sig in 0 ..< WANG_SIGNATURES {
		for v in 0 ..< int(b.variants) {
			tile := wang_tile_id(b, Wang_Signature(sig), v)
			want := Cell(wang_west(Wang_Signature(sig)) == 1 ? 7 : 0)
			testing.expectf(
				t,
				tile_at(set, tile, x, y) == want,
				"tile %d (west %d) holds %d",
				sig,
				wang_west(Wang_Signature(sig)),
				tile_at(set, tile, x, y),
			)
		}
	}

	// A cell in the middle is the tile's own.
	mid_x, mid_y := i32(TILE_SIZE / 2), i32(TILE_SIZE / 2)
	tile_set_cell(set, wang_tile_id(b, source, 0), mid_x, mid_y, 9)
	testing.expect(t, tile_at(set, wang_tile_id(b, source, 1), mid_x, mid_y) == 0, "a variant keeps its own middle")

	// A corner belongs to the whole set, so one stroke reaches all of it.
	wang_paint_cell(set, b, source, 0, 0, 5)
	for i in 0 ..< wang_set_size(b) {
		testing.expect(t, tile_at(set, Tile_Id(i), 0, 0) == 5, "a corner is common to the set")
	}
}

@(test)
test_wang_normalize_repairs_a_broken_seam :: proc(t: ^testing.T) {
	b, set := make_test_set(1)
	defer destroy_tile_set(set)

	for i in 0 ..< wang_set_size(b) do tile_fill(set, Tile_Id(i), 0)
	testing.expect(t, !wang_find_conflict(set, b).found, "a flat set agrees with itself")

	// A file painted somewhere else: one tile with a different west
	// band from the rest of its color.
	broken := wang_tile_id(b, wang_signature(1, 1, 1, 1), 0)
	tile_set_cell(set, broken, 0, TILE_SIZE / 2, 3)

	conflict := wang_find_conflict(set, b)
	testing.expect(t, conflict.found, "the gate must see the broken seam")
	testing.expect(t, conflict.x == 0 && conflict.y == TILE_SIZE / 2, "and say which cell it is")

	changed := wang_normalize(set, b)
	testing.expect(t, changed == 1, "one cell was out of step")
	testing.expect(t, !wang_find_conflict(set, b).found, "and the set agrees again")
}

/*
The world picks a tile that fits, and over an area it picks every
variant. Without the second half a variant nobody draws is dead
authoring.
*/
@(test)
test_wang_tile_at_fits_the_square_and_uses_every_variant :: proc(t: ^testing.T) {
	b, set := make_test_set(3)
	defer destroy_tile_set(set)

	seen_variant: [3]bool
	seen_signature: [WANG_SIGNATURES]bool

	for sy in i32(-20) ..< i32(20) {
		for sx in i32(-20) ..< i32(20) {
			tile := wang_tile_at(1, b, sx, sy)
			testing.expectf(t, int(tile) < wang_set_size(b), "tile %d is outside the set", tile)

			testing.expectf(
				t,
				wang_signature_of(b, tile) == wang_signature_at(1, sx, sy),
				"the tile at %d,%d does not carry the edges of that square",
				sx,
				sy,
			)
			testing.expect(t, wang_tile_at(1, b, sx, sy) == tile, "the same square must give the same tile")

			seen_variant[wang_variant_of(b, tile)] = true
			seen_signature[wang_signature_of(b, tile)] = true
		}
	}

	for used, v in seen_variant do testing.expectf(t, used, "variant %d never came up", v)
	for used, sig in seen_signature do testing.expectf(t, used, "signature %d never came up", sig)
}
