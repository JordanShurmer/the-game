package game

import "core:fmt"
import testing "check"

WANG_COLORS :: 2
WANG_BITS :: 1

#assert(1 << WANG_BITS == WANG_COLORS)

WANG_SIGNATURES :: WANG_COLORS * WANG_COLORS * WANG_COLORS * WANG_COLORS

WANG_SEAM :: 4

#assert(WANG_SEAM > 0 && WANG_SEAM * 2 < TILE_SIZE, "the two seams of an axis must not meet")

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

WANG_SALT_HORIZONTAL :: 0x0000_0000_0000_0001
WANG_SALT_VERTICAL :: 0x0000_0000_0000_0002
WANG_SALT_VARIANT :: 0x0000_0000_0000_0003

wang_horizontal_edge :: proc(seed: u64, hx, hy: i32) -> u8 {
	return u8(wang_hash(seed, WANG_SALT_HORIZONTAL, hx, hy) & (WANG_COLORS - 1))
}

wang_vertical_edge :: proc(seed: u64, vx, vy: i32) -> u8 {
	return u8(wang_hash(seed, WANG_SALT_VERTICAL, vx, vy) & (WANG_COLORS - 1))
}

wang_signature_at :: proc(seed: u64, sx, sy: i32) -> Wang_Signature {
	n := wang_horizontal_edge(seed, sx, sy)
	s := wang_horizontal_edge(seed, sx, sy + 1)
	w := wang_vertical_edge(seed, sx, sy)
	e := wang_vertical_edge(seed, sx + 1, sy)
	return wang_signature(n, e, s, w)
}

wang_tile_at :: proc(seed: u64, b: Biome, sx, sy: i32) -> Tile_Id {
	sig := wang_signature_at(seed, sx, sy)
	variant := 0
	if b.variants > 1 {
		variant = int(wang_hash(seed, WANG_SALT_VARIANT, sx, sy) % u64(b.variants))
	}
	return wang_tile_id(b, sig, variant)
}

wang_tile_id :: proc(b: Biome, sig: Wang_Signature, variant: int) -> Tile_Id {
	return b.tile_base + Tile_Id(int(sig) * int(b.variants) + variant)
}

WANG_MAX_VARIANTS :: 8

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

wang_set_size :: proc(b: Biome) -> int {
	if b.tile_base == TILE_NONE do return 0
	return WANG_SIGNATURES * int(b.variants)
}

wang_signature_of :: proc(b: Biome, tile: Tile_Id) -> Wang_Signature {
	return Wang_Signature((int(tile) - int(b.tile_base)) / int(b.variants))
}

wang_variant_of :: proc(b: Biome, tile: Tile_Id) -> int {
	return (int(tile) - int(b.tile_base)) % int(b.variants)
}

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

Wang_Conflict :: struct {
	a:     Tile_Id,
	b:     Tile_Id,
	x:     i32,    
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

@(test)
test_wang_paint_reaches_the_edge_color_and_no_further :: proc(t: ^testing.T) {
	b, set := make_test_set(2)
	defer destroy_tile_set(set)

	for i in 0 ..< wang_set_size(b) do tile_fill(set, Tile_Id(i), 0)

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

	mid_x, mid_y := i32(TILE_SIZE / 2), i32(TILE_SIZE / 2)
	tile_set_cell(set, wang_tile_id(b, source, 0), mid_x, mid_y, 9)
	testing.expect(t, tile_at(set, wang_tile_id(b, source, 1), mid_x, mid_y) == 0, "a variant keeps its own middle")

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

	broken := wang_tile_id(b, wang_signature(1, 1, 1, 1), 0)
	tile_set_cell(set, broken, 0, TILE_SIZE / 2, 3)

	conflict := wang_find_conflict(set, b)
	testing.expect(t, conflict.found, "the gate must see the broken seam")
	testing.expect(t, conflict.x == 0 && conflict.y == TILE_SIZE / 2, "and say which cell it is")

	changed := wang_normalize(set, b)
	testing.expect(t, changed == 1, "one cell was out of step")
	testing.expect(t, !wang_find_conflict(set, b).found, "and the set agrees again")
}

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
