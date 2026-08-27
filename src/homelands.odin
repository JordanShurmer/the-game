package game

import "core:testing"

// The homelands.
//
// Six regions of field and cottage laid west to east along the surface
// row of the biome map, and a seventh east of them where the ground
// rises and the coal begins. There is no homelands code: the biome is
// an image set, the pictures are drawn by `tools/seed_homelands.py`,
// and the world reads them through the same `generator = image` path a
// gallery goes through. What is here is the shape the rest of the game
// expects the homelands to have, and the tests that hold the shipped
// world to it.
//
// See docs/homelands.md.

HOMELANDS_NAME :: "Homelands"
HOMELANDS_REGIONS :: 6
HOMELANDS_PICTURES :: 12

// The region east of the last homeland, which is where the caves are
// entered from the fields.
CAVEMOUTH_NAME :: "Cavemouth"

// The map pixels of one biome, west to east and then row by row.
biome_map_regions_of :: proc(
	world: World,
	id: Biome_Id,
	out: ^[dynamic][2]i32,
) {
	clear(out)
	m := world.biome_map
	for y in 0 ..< m.height {
		for x in 0 ..< m.width {
			if biome_map_at(m, x, y) == id do append(out, [2]i32{x, y})
		}
	}
}

@(test)
test_the_homelands_are_a_row_of_six_on_the_surface :: proc(t: ^testing.T) {
	s: Sim
	if !testing.expect(t, sim_load(&s) == .None, "the world must load") do return
	defer sim_unload(&s)

	id, found := find_biome_index(s.world.biomes, HOMELANDS_NAME)
	if !testing.expect(t, found, "the shipped world must hold the homelands") do return

	b := s.world.biomes.biomes[id]
	testing.expectf(
		t, b.generator == .Image,
		"the homelands are painted pictures, and the biome says %v", b.generator,
	)
	testing.expectf(
		t, int(b.variants) == HOMELANDS_PICTURES,
		"the set is %d pictures, and the biome owns %d", HOMELANDS_PICTURES, b.variants,
	)

	regions := make([dynamic][2]i32)
	defer delete(regions)
	biome_map_regions_of(s.world, Biome_Id(id), &regions)

	testing.expectf(
		t, len(regions) == HOMELANDS_REGIONS,
		"the homelands are %d regions, and the map holds %d", HOMELANDS_REGIONS, len(regions),
	)
	if len(regions) != HOMELANDS_REGIONS do return

	// One row, and no gap in it: the wizard walks the whole village
	// without leaving it.
	for r, i in regions {
		testing.expectf(t, r.y == regions[0].y, "region %d is on another row", i)
		if i > 0 do testing.expectf(t, r.x == regions[i - 1].x + 1, "there is a gap before region %d", i)
	}

	// And the sky is directly over them, so it is a surface and not a
	// room with earth on top of it.
	sky, sky_found := find_biome_index(s.world.biomes, "Sky")
	if !testing.expect(t, sky_found, "the world must have a sky") do return
	for r in regions {
		testing.expectf(
			t, int(biome_map_at(s.world.biome_map, r.x, r.y - 1)) == sky,
			"the region at %d,%d has no sky over it", r.x, r.y,
		)
	}
}

@(test)
test_the_homelands_regions_are_not_all_the_same_picture :: proc(t: ^testing.T) {
	s: Sim
	if !testing.expect(t, sim_load(&s) == .None, "the world must load") do return
	defer sim_unload(&s)

	id, found := find_biome_index(s.world.biomes, HOMELANDS_NAME)
	if !testing.expect(t, found) do return
	b := s.world.biomes.biomes[id]

	regions := make([dynamic][2]i32)
	defer delete(regions)
	biome_map_regions_of(s.world, Biome_Id(id), &regions)
	if !testing.expect(t, len(regions) > 1) do return

	seen: map[int]bool
	defer delete(seen)
	for r in regions {
		v := world_image_variant(
			s.world, b,
			r.x - s.world.biomes.origin_pixel_x,
			r.y - s.world.biomes.origin_pixel_y,
		)
		testing.expectf(t, v >= 0 && v < int(b.variants), "picture %d is outside the set", v)
		seen[v] = true
	}
	testing.expectf(
		t, len(seen) >= 4,
		"six regions drawn from twelve pictures must not come out as %d of them", len(seen),
	)

	// And the whole set must be reachable, or a picture is drawn for
	// nothing: run the lattice past the six the shipped map holds.
	all: map[int]bool
	defer delete(all)
	for x in i32(-60) ..< i32(60) {
		all[world_image_variant(s.world, b, x, 0)] = true
	}
	testing.expectf(
		t, len(all) == int(b.variants),
		"every one of the %d pictures must be able to come up, and %d did", b.variants, len(all),
	)
}

// How far east a wizard must get in twenty seconds of walking and
// jumping, which is what a player does in the first seconds of a game.
//
// It is deliberately short of the whole village. He clears about
// twenty-eight cells from a standing jump, so a fence, a hedge bank and
// a garden wall are all things he goes over without thinking; a cottage
// stands higher than that and he flies over it, which is what the
// jetpack is for. So this asks one thing only: that he is not walled in
// where he lands, and gets clear of the green and into the fields.
//
// The rule about the ground itself -- that nothing worked into a field
// may stand higher than PLAYER_CLIMB -- is held precisely, on every one
// of the twelve pictures, by `tools/seed_homelands.py --check`. This is
// the same rule asked of the running game, where it is coarse but real:
// it read 44 when the crops were solid and the furrows were eight cells
// deep, which is the state it exists to catch.
HOMELANDS_WALK :: 90

@(test)
test_walking_east_out_of_the_village_gets_him_somewhere :: proc(t: ^testing.T) {
	s: Sim
	if !testing.expect(t, sim_load(&s) == .None, "the world must load") do return
	defer sim_unload(&s)
	sim_play_begin(&s)

	start := s.player.x
	for i in 0 ..< 60 * 20 {
		sim_step_player(&s, {.Right}, i % 24 == 0)
	}
	walked := s.player.x - start

	testing.expectf(
		t, walked >= HOMELANDS_WALK,
		"twenty seconds of walking and jumping east took him %.0f cells and it must take him %d; something is standing in the ground of the village where he lands",
		walked, HOMELANDS_WALK,
	)
}

@(test)
test_the_caves_open_east_of_the_last_homeland :: proc(t: ^testing.T) {
	s: Sim
	if !testing.expect(t, sim_load(&s) == .None, "the world must load") do return
	defer sim_unload(&s)

	home, home_found := find_biome_index(s.world.biomes, HOMELANDS_NAME)
	mouth, mouth_found := find_biome_index(s.world.biomes, CAVEMOUTH_NAME)
	if !testing.expect(t, home_found && mouth_found, "both biomes must exist") do return

	regions := make([dynamic][2]i32)
	defer delete(regions)
	biome_map_regions_of(s.world, Biome_Id(home), &regions)
	if !testing.expect(t, len(regions) > 0) do return

	last := regions[len(regions) - 1]
	testing.expectf(
		t, int(biome_map_at(s.world.biome_map, last.x + 1, last.y)) == mouth,
		"the pixel east of the last homeland must be the %s, and it is %s",
		CAVEMOUTH_NAME,
		s.world.biomes.names[biome_map_at(s.world.biome_map, last.x + 1, last.y)],
	)

	// Walk in from the fields at the height a wizard walks at, and see
	// that the open space he is in reaches the coal under the region.
	cpp := s.world.biomes.cells_per_pixel
	left := (last.x + 1 - s.world.biomes.origin_pixel_x) * cpp
	top := (last.y - s.world.biomes.origin_pixel_y) * cpp

	// Stand on the last field, a few cells short of the mouth.
	approach_x := left - 4
	ground := top
	for ground < top + cpp && material_is_open(s.world.materials, world_cell_at(s.world, approach_x, ground)) {
		ground += 1
	}
	if !testing.expect(t, ground > top && ground < top + cpp, "the last field must have a ground line") do return

	reached := cave_is_reached_from(s.world, approach_x, ground - 2, left, top, cpp)
	testing.expect(
		t, reached,
		"an open way must run from the last field, in through the mouth, and down into the coal",
	)
}

// A flood through open cells, from one cell, asking whether it leaves
// the bottom of the region it starts in. Bounded to the region and the
// two columns of field west of it, so it measures the mouth and not the
// whole world.
@(private = "file")
cave_is_reached_from :: proc(world: World, from_x, from_y, left, top, cpp: i32) -> bool {
	x0 := left - 8
	x1 := left + cpp - 1
	y0 := top
	y1 := top + cpp - 1

	w := int(x1 - x0 + 1)
	seen := make([]bool, w * int(y1 - y0 + 1))
	defer delete(seen)

	stack := make([dynamic][2]i32, 0, 4096)
	defer delete(stack)
	append(&stack, [2]i32{from_x, from_y})

	for len(stack) > 0 {
		p := pop(&stack)
		if p.x < x0 || p.x > x1 || p.y < y0 || p.y > y1 do continue
		i := int(p.y - y0) * w + int(p.x - x0)
		if seen[i] do continue
		if !material_is_open(world.materials, world_cell_at(world, p.x, p.y)) do continue
		seen[i] = true
		if p.y == y1 do return true
		append(&stack, [2]i32{p.x + 1, p.y})
		append(&stack, [2]i32{p.x - 1, p.y})
		append(&stack, [2]i32{p.x, p.y + 1})
		append(&stack, [2]i32{p.x, p.y - 1})
	}
	return false
}

@(private = "file")
material_is_open :: proc(table: Material_Table, c: Cell) -> bool {
	state := table.materials[c].state
	return state != .Solid && state != .Powder
}
