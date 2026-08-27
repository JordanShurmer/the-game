package game

import "core:testing"

// The pond is a tile.
//
// It used to be an overlay dug beside the spawn, because the spawn was
// beside a cave mouth and a pond was the one landmark the surface had.
// The surface is a village now and the village is daylit, and a pond
// of fireflies belongs in the dark, so the pond moved underground --
// into the Grotto, one authored tile of the Coalmine's wang set,
// painted by tools/seed_tiles.py: a dome of cave over a rock bowl of
// still water, sealed on every side but the east.
//
// Nothing in the game knows that. The water is cells of the tile, read
// through the same path as every other cell; the fireflies are cells
// of Firefly_Light painted over the water, lifted out by the loader as
// marks (see Tile_Mark) and gathered into the swarm by firefly_gather.
// The lattice decides where the Grotto's instances lie, so every world
// has its own ponds in its own places, and another tile of another
// biome could paint a pond of its own without touching a line of code.
//
// What is here is the tests that hold the shipped Grotto to being a
// pond: water that cannot leak, fireflies that hang over water, and at
// least one of it within digging reach of the village.

// The tile the shipped world's firefly marks are painted in. The marks
// are the only thing that names it: the tile that carries fireflies is
// the pond, whichever tile that is.
@(private = "file")
grotto_of :: proc(world: ^World, t: ^testing.T) -> (tile: Tile_Id, ok: bool) {
	firefly := world.materials.firefly
	for m in world.tiles.marks {
		if m.material == firefly do return m.tile, true
	}
	testing.expect(t, false, "some tile of the shipped world must carry firefly marks")
	return TILE_NONE, false
}

@(test)
test_the_grotto_holds_its_water_in_a_bowl_that_cannot_leak :: proc(t: ^testing.T) {
	s: Sim
	if !testing.expect(t, sim_load(&s) == .None, "the world must load") do return
	defer sim_unload(&s)

	tile, ok := grotto_of(&s.world, t)
	if !ok do return

	water, _ := find_material_index(s.world.materials, "Water")
	air, _ := find_material_index(s.world.materials, "Air")

	cells := 0
	leaks := 0
	for y in i32(1) ..< TILE_SIZE - 1 {
		for x in i32(1) ..< TILE_SIZE - 1 {
			if tile_at(s.world.tiles, tile, x, y) != Cell(water) do continue
			cells += 1

			for step in ([4][2]i32{{1, 0}, {-1, 0}, {0, 1}, {0, -1}}) {
				n := tile_at(s.world.tiles, tile, x + step[0], y + step[1])
				if n == Cell(air) && step[1] >= 0 do leaks += 1
			}
		}
	}

	testing.expect(t, cells > 1000, "the Grotto must hold a pond, not a puddle")
	testing.expectf(
		t,
		leaks == 0,
		"water may meet air only above itself, and %d cells of it do not",
		leaks,
	)
}

@(test)
test_the_fireflies_hang_over_water_within_reach_of_the_village :: proc(t: ^testing.T) {
	s: Sim
	if !testing.expect(t, sim_load(&s) == .None, "the world must load") do return
	defer sim_unload(&s)

	if !testing.expect(t, s.flies.count > 0, "the shipped world must gather a swarm") do return

	water, _ := find_material_index(s.world.materials, "Water")

	// Every fly hangs in open air with the pond's water below it.
	for i in 0 ..< int(s.flies.count) {
		f := s.flies.flies[i]
		x := i32(f.home_x)
		y := i32(f.home_y)

		testing.expectf(
			t,
			world_cell_at(s.world, x, y) == MATERIAL_AIR,
			"a firefly hangs in the air, and one was painted into %s at %d,%d",
			s.world.materials.names[world_cell_at(s.world, x, y)], x, y,
		)

		wet := false
		for dy in i32(1) ..= 48 {
			c := world_cell_at(s.world, x, y + dy)
			if c == Cell(water) {
				wet = true
				break
			}
			if c != MATERIAL_AIR do break
		}
		testing.expectf(t, wet, "and over water, and the one at %d,%d is not", x, y)
	}

	// And the nearest of them is a short dig from where he starts: the
	// pond is the reward for going down, not a rumour three squares off.
	nearest := max(f32)
	for i in 0 ..< int(s.flies.count) {
		f := s.flies.flies[i]
		dx := abs(f.home_x - s.player.x)
		dy := abs(f.home_y - s.player.y)
		nearest = min(nearest, max(dx, dy))
	}
	testing.expectf(
		t,
		nearest < 3 * TILE_SIZE,
		"the nearest firefly must be within three tiles of the spawn, and it is %.0f cells away",
		nearest,
	)
}
