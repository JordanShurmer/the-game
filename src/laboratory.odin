package game

import "core:testing"

// The Laboratory: the world one seed opens instead of laying the
// ordinary map out again.
//
// A seed is a world. Every seed draws the same map another way -- which
// tile of a wang set each square of the lattice takes, and which of an
// image biome's pictures each of its regions takes -- and the map
// itself, data/biome_map.png, is the same map either way: the
// homelands, the mouth east of them, and the coal and the lake and the
// deep rock under all of it.
//
// One seed is not that. `[Laboratory]` in data/biomes.txt names it, and
// it opens another map picture altogether. That map is the museum: the
// physics gallery and the alchemy gallery side by side under an open
// sky, and rock everywhere else. Their two bedrock roofs are one floor
// under the day, and the wizard lands on it halfway between the two
// doors, which are the entrance shafts cut down through the top edge of
// each gallery's own picture.
//
// The galleries keep the world coordinates every note already gives
// them, because the Laboratory map is drawn at the same size against
// the same origin: the physics gallery is world x 0 to 511 and the
// alchemy gallery x 512 to 1023, both y -2560 to -2049.
//
// See docs/laboratory.md. tools/seed_laboratory.py draws the map and
// holds it to its rules.
Laboratory :: struct {
	// The seed that opens it. 0 when data/biomes.txt names no
	// Laboratory at all, which is why 0 opens nothing.
	seed:           u64,
	map_image_path: string,
	spawn_biome:    Biome_Id,
	spawn_region:   i32,
}

// What a seed opens: the map picture the world is painted on, and where
// on it the wizard starts. Every seed but one gives the ordinary map
// back, which is why a seed changes the drawing and not the place.
World_Layout :: struct {
	map_image_path: string,
	spawn_biome:    Biome_Id,
	spawn_region:   i32,
}

world_layout :: proc(table: Biome_Table, seed: u64) -> World_Layout {
	if world_is_laboratory(table, seed) {
		return World_Layout {
			map_image_path = table.laboratory.map_image_path,
			spawn_biome    = table.laboratory.spawn_biome,
			spawn_region   = table.laboratory.spawn_region,
		}
	}
	return World_Layout {
		map_image_path = table.map_image_path,
		spawn_biome    = table.spawn_biome,
		spawn_region   = table.spawn_region,
	}
}

world_is_laboratory :: proc(table: Biome_Table, seed: u64) -> bool {
	return table.laboratory.seed != 0 && seed == table.laboratory.seed
}

LABORATORY_HALLS :: 2  // the physics gallery and the alchemy gallery

// The two galleries, west to east. Every note gives a room of one of
// them a world coordinate, and those coordinates are these.
GALLERY_NAME :: "Gallery"
ALCHEMY_NAME :: "Alchemy"

// The seed the file names, read from the file rather than written down
// here a second time.
@(private = "file")
laboratory_seed :: proc(t: ^testing.T) -> (seed: u64, ok: bool) {
	materials, mat_ok := load_materials(MATERIALS_PATH)
	if !testing.expect(t, mat_ok, "materials must load") do return 0, false
	defer destroy_material_table(materials)

	table, err, line := load_biomes(BIOMES_PATH, materials)
	if !testing.expectf(t, err == .None, "biomes must load, got %v at line %d", err, line) {
		return 0, false
	}
	defer destroy_biome_table(table)

	seed = table.laboratory.seed
	return seed, testing.expectf(t, seed != 0, "%s must name a Laboratory seed", BIOMES_PATH)
}

@(private = "file")
open_laboratory :: proc(t: ^testing.T, s: ^Sim) -> bool {
	seed, ok := laboratory_seed(t)
	if !ok do return false
	return testing.expect(t, sim_load(s, seed = seed) == .None, "the Laboratory must load")
}

// The top left world cell of a biome's only region, and the biome id.
@(private = "file")
only_region_of :: proc(t: ^testing.T, world: World, name: string) -> (id: Biome_Id, x, y: i32, ok: bool) {
	idx, found := find_biome_index(world.biomes, name)
	if !testing.expectf(t, found, "there must be a biome named %s", name) do return 0, 0, 0, false

	regions := make([dynamic][2]i32)
	defer delete(regions)
	biome_map_regions_of(world, Biome_Id(idx), &regions)

	if !testing.expectf(
		t,
		len(regions) == 1,
		"%s must be one region of this world, and the map holds %d",
		name,
		len(regions),
	) {
		return 0, 0, 0, false
	}

	cpp := world.biomes.cells_per_pixel
	x = (regions[0].x - world.biomes.origin_pixel_x) * cpp
	y = (regions[0].y - world.biomes.origin_pixel_y) * cpp
	return Biome_Id(idx), x, y, true
}

// The doors of the museum: the runs of open cell along the roof row.
// Every gallery cuts one down through the top edge of its own picture,
// and there is nothing else up there to fall through.
@(private = "file")
Door :: struct {
	x0, x1: i32, // inclusive
}

@(private = "file")
roof_doors :: proc(s: ^Sim, roof_y, from_x, to_x: i32, out: ^[dynamic]Door) {
	clear(out)
	terrain := Terrain{world = &s.world}
	open := false
	for x in from_x ..= to_x {
		if !player_solid_at(terrain, x, roof_y) {
			if !open do append(out, Door{x0 = x, x1 = x})
			else do out[len(out) - 1].x1 = x
			open = true
			continue
		}
		open = false
	}
}

@(test)
test_the_laboratory_is_the_two_galleries_under_one_sky :: proc(t: ^testing.T) {
	s: Sim
	if !open_laboratory(t, &s) do return
	defer sim_unload(&s)

	testing.expect(
		t, world_is_laboratory(s.world.biomes, s.world.seed),
		"the seed the file names must open the Laboratory",
	)

	gallery, gx, gy, g_ok := only_region_of(t, s.world, GALLERY_NAME)
	alchemy, ax, ay, a_ok := only_region_of(t, s.world, ALCHEMY_NAME)
	if !g_ok || !a_ok do return

	cpp := s.world.biomes.cells_per_pixel
	testing.expectf(
		t, ay == gy,
		"the two halls must share a row, or their roofs are not one floor: %d and %d", gy, ay,
	)
	testing.expectf(
		t, ax == gx + cpp,
		"the alchemy gallery must sit against the physics one, and it starts %d cells east", ax - gx,
	)

	// Open sky the whole way up over both, so the roof is under the
	// day and the day lights it. See docs/lighting.md, "The day is a
	// biome".
	sky, sky_found := find_biome_index(s.world.biomes, "Sky")
	if !testing.expect(t, sky_found, "the world must have a sky") do return

	m := s.world.biome_map
	for id in ([2]Biome_Id{gallery, alchemy}) {
		for px in 0 ..< m.width {
			for py in 0 ..< m.height {
				if biome_map_at(m, px, py) != id do continue
				for above in 0 ..< py {
					testing.expectf(
						t, int(biome_map_at(m, px, above)) == sky,
						"the pixel at %d,%d over %s is %s, and it must be open sky",
						px, above, s.world.biomes.names[id],
						s.world.biomes.names[biome_map_at(m, px, above)],
					)
				}
			}
		}
	}
}

@(test)
test_the_galleries_keep_the_coordinates_the_notes_give_them :: proc(t: ^testing.T) {
	s: Sim
	if !open_laboratory(t, &s) do return
	defer sim_unload(&s)

	// docs/physics.md and docs/alchemy.md give a room of each gallery a
	// world coordinate, and every shot command in them is written from
	// these two. Moving the museum into its own world must not move it.
	_, gx, gy, g_ok := only_region_of(t, s.world, GALLERY_NAME)
	_, ax, ay, a_ok := only_region_of(t, s.world, ALCHEMY_NAME)
	if !g_ok || !a_ok do return

	testing.expectf(t, gx == 0 && gy == -2560, "the physics gallery starts at 0,-2560, and it is at %d,%d", gx, gy)
	testing.expectf(t, ax == 512 && ay == -2560, "the alchemy gallery starts at 512,-2560, and it is at %d,%d", ax, ay)
}

@(test)
test_the_ordinary_world_no_longer_holds_the_galleries :: proc(t: ^testing.T) {
	s: Sim
	if !testing.expect(t, sim_load(&s) == .None, "the world must load") do return
	defer sim_unload(&s)

	testing.expect(
		t, !world_is_laboratory(s.world.biomes, s.world.seed),
		"the shipped seed is not the Laboratory seed",
	)

	regions := make([dynamic][2]i32)
	defer delete(regions)

	for name in ([2]string{GALLERY_NAME, ALCHEMY_NAME}) {
		idx, found := find_biome_index(s.world.biomes, name)
		if !testing.expectf(t, found, "the biome %s must still be defined", name) do continue
		biome_map_regions_of(s.world, Biome_Id(idx), &regions)
		testing.expectf(
			t, len(regions) == 0,
			"%s belongs to the Laboratory now, and the ordinary map still paints %d region(s) of it",
			name, len(regions),
		)
	}
}

@(test)
test_the_museum_roof_has_one_door_a_hall_and_nothing_else :: proc(t: ^testing.T) {
	s: Sim
	if !open_laboratory(t, &s) do return
	defer sim_unload(&s)

	_, gx, gy, g_ok := only_region_of(t, s.world, GALLERY_NAME)
	_, ax, _, a_ok := only_region_of(t, s.world, ALCHEMY_NAME)
	if !g_ok || !a_ok do return

	cpp := s.world.biomes.cells_per_pixel
	doors := make([dynamic]Door)
	defer delete(doors)
	roof_doors(&s, gy, gx, ax + cpp - 1, &doors)

	if !testing.expectf(
		t,
		len(doors) == LABORATORY_HALLS,
		"the roof must hold one door a hall, and it holds %d",
		len(doors),
	) {
		return
	}

	for d, i in doors {
		width := d.x1 - d.x0 + 1
		testing.expectf(
			t, width >= PLAYER_BODY_W,
			"door %d is %d cells wide, and the wizard is %d", i, width, i32(PLAYER_BODY_W),
		)
	}
	testing.expectf(t, doors[0].x0 >= gx && doors[0].x1 < ax, "the first door must be the physics one")
	testing.expectf(t, doors[1].x0 >= ax, "the second door must be the alchemy one")
}

@(test)
test_the_laboratory_lands_him_on_the_roof_between_the_two_doors :: proc(t: ^testing.T) {
	s: Sim
	if !open_laboratory(t, &s) do return
	defer sim_unload(&s)

	gallery, gx, gy, g_ok := only_region_of(t, s.world, GALLERY_NAME)
	_, ax, _, a_ok := only_region_of(t, s.world, ALCHEMY_NAME)
	if !g_ok || !a_ok do return

	p := s.player
	testing.expectf(
		t, world_biome_at(s.world, i32(p.x), i32(p.y)) == gallery,
		"he must land on the physics gallery's own region, and he is on %s",
		s.world.biomes.names[world_biome_at(s.world, i32(p.x), i32(p.y))],
	)
	testing.expectf(t, i32(p.y) == gy, "he must land on the roof row %d, and he is at %d", gy, i32(p.y))
	testing.expect(t, p.on_ground, "the roof must hold him up")

	terrain := Terrain{world = &s.world}
	testing.expect(t, player_body_clear(terrain, p.x, p.y), "there must be room for him where he lands")

	cpp := s.world.biomes.cells_per_pixel
	doors := make([dynamic]Door)
	defer delete(doors)
	roof_doors(&s, gy, gx, ax + cpp - 1, &doors)
	if !testing.expect(t, len(doors) == LABORATORY_HALLS) do return

	// Between the two, and not on top of either: the walk to the
	// physics door and the walk to the alchemy door are the same walk
	// the other way.
	testing.expectf(
		t, i32(p.x) > doors[0].x1 && i32(p.x) < doors[1].x0,
		"he must land between the two doors, and he lands at %d with doors at %d and %d",
		i32(p.x), doors[0].x1, doors[1].x0,
	)
}

// A leg of the walk is generous: the point of the cap is that a broken
// world stops the test rather than hanging it.
@(private = "file")
LAB_LEG_TICKS :: 1500

// He is inside a hall once he is a body's length below the roof.
@(private = "file")
LAB_INSIDE :: 2 * PLAYER_BODY_H

// The wizard walks the Laboratory: out of where he lands, down the
// physics door, back up it on the jetpack, east along the roof, and
// down the alchemy door. Every leg is the keys a hand would hold, so
// nothing here is staged -- it is the same path through
// sim_step_player the window drives.
//
// The world is the painted one, with no sandbox over it: this asks
// whether the museum can be walked, not what its liquids do once they
// start moving. What they do is measured in src/alchemy_test.odin and
// looked at in a shot.
@(test)
test_the_wizard_walks_the_laboratory_into_both_galleries :: proc(t: ^testing.T) {
	s: Sim
	if !open_laboratory(t, &s) do return
	defer sim_unload(&s)

	gallery, gx, roof, g_ok := only_region_of(t, s.world, GALLERY_NAME)
	alchemy, ax, _, a_ok := only_region_of(t, s.world, ALCHEMY_NAME)
	if !g_ok || !a_ok do return

	cpp := s.world.biomes.cells_per_pixel
	doors := make([dynamic]Door)
	defer delete(doors)
	roof_doors(&s, roof, gx, ax + cpp - 1, &doors)
	if !testing.expect(t, len(doors) == LABORATORY_HALLS, "the roof must hold two doors") do return

	standing_in :: proc(s: ^Sim) -> Biome_Id {
		return world_biome_at(s.world, i32(s.player.x), i32(s.player.y))
	}

	// West, off the roof and down the physics door.
	fell := false
	for _ in 0 ..< LAB_LEG_TICKS {
		sim_step_player(&s, {.Left}, false)
		if i32(s.player.y) > roof + LAB_INSIDE {
			fell = true
			break
		}
	}
	if !testing.expectf(
		t,
		fell,
		"walking west off the landing must find the physics door, and he is at %.0f,%.0f",
		s.player.x,
		s.player.y,
	) {
		return
	}
	testing.expectf(
		t, standing_in(&s) == gallery,
		"the door must drop him into the physics gallery, and he is in %s",
		s.world.biomes.names[standing_in(&s)],
	)

	// Down to the floor of room 1, against its west wall, which is
	// under the door he came in by.
	for _ in 0 ..< 300 do sim_step_player(&s, {.Left}, false)
	testing.expect(t, s.player.on_ground, "the floor of the first room must hold him up")
	testing.expectf(
		t,
		i32(s.player.x) >= doors[0].x0 && i32(s.player.x) <= doors[0].x1,
		"he must come to rest under the door he fell through, and he is at %.0f",
		s.player.x,
	)

	// Up again on the jetpack, the way out of a hall.
	out := false
	pressed := true
	for _ in 0 ..< LAB_LEG_TICKS {
		sim_step_player(&s, {.Jump}, pressed)
		pressed = false
		if i32(s.player.y) < roof {
			out = true
			break
		}
	}
	if !testing.expectf(
		t,
		out,
		"one tank of fuel must lift him out of a hall, and he reached %.0f with the roof at %d",
		s.player.y,
		roof,
	) {
		return
	}

	// East, clear of the door he came out of, and back down onto the roof.
	clear_x := doors[0].x1 + PLAYER_BODY_W + 4
	for _ in 0 ..< LAB_LEG_TICKS {
		sim_step_player(&s, {.Jump, .Right}, false)
		if i32(s.player.x) > clear_x && i32(s.player.y) < roof do break
	}
	landed := false
	for _ in 0 ..< LAB_LEG_TICKS {
		sim_step_player(&s, {.Right}, false)
		if s.player.on_ground {
			landed = true
			break
		}
	}
	if !testing.expectf(
		t,
		landed && i32(s.player.y) == roof,
		"he must come down on the roof again, and he is at %.0f,%.0f",
		s.player.x,
		s.player.y,
	) {
		return
	}

	// East along the roof to the other door.
	fell = false
	for _ in 0 ..< LAB_LEG_TICKS {
		sim_step_player(&s, {.Right, .Run}, false)
		if i32(s.player.y) > roof + LAB_INSIDE {
			fell = true
			break
		}
	}
	if !testing.expectf(
		t,
		fell,
		"running east along the roof must find the alchemy door, and he is at %.0f,%.0f",
		s.player.x,
		s.player.y,
	) {
		return
	}
	testing.expectf(
		t, standing_in(&s) == alchemy,
		"the second door must drop him into the alchemy gallery, and he is in %s",
		s.world.biomes.names[standing_in(&s)],
	)
}

// A seed given on the command line reaches the world, the lattice and
// the light. Every seed but one is the same map drawn again, so the
// wizard still starts in the homelands and the museum is still not
// there to be found.
@(test)
test_another_seed_is_the_same_map_drawn_again :: proc(t: ^testing.T) {
	lab, seed_ok := laboratory_seed(t)
	if !seed_ok do return

	other := lab + 1

	s: Sim
	if !testing.expect(t, sim_load(&s, seed = other) == .None, "another seed must open a world") do return
	defer sim_unload(&s)

	testing.expectf(t, s.world.seed == other, "the world must take the seed it is given, and it has %d", s.world.seed)
	testing.expectf(t, s.light.seed == other, "the light must take it too, and it has %d", s.light.seed)
	testing.expect(t, !world_is_laboratory(s.world.biomes, s.world.seed), "only the one seed opens the Laboratory")

	home, home_found := find_biome_index(s.world.biomes, HOMELANDS_NAME)
	if !testing.expect(t, home_found) do return
	testing.expectf(
		t, world_biome_at(s.world, i32(s.player.x), i32(s.player.y)) == Biome_Id(home),
		"he must still start in the homelands, and he is on %s",
		s.world.biomes.names[world_biome_at(s.world, i32(s.player.x), i32(s.player.y))],
	)

	regions := make([dynamic][2]i32)
	defer delete(regions)
	gallery, gallery_found := find_biome_index(s.world.biomes, GALLERY_NAME)
	if !testing.expect(t, gallery_found) do return
	biome_map_regions_of(s.world, Biome_Id(gallery), &regions)
	testing.expect(t, len(regions) == 0, "the museum belongs to the one seed that opens it")
}

// The same seed opens the same world twice, and two seeds do not draw
// the same one. This is the whole of what a seed promises.
@(test)
test_a_seed_draws_one_world_and_two_seeds_draw_two :: proc(t: ^testing.T) {
	view := World_View{x = -2048, y = -2560, w = 256, h = 192, step = 3}

	draw :: proc(t: ^testing.T, seed: u64, view: World_View) -> ([]Cell, bool) {
		s: Sim
		if !testing.expectf(t, sim_load(&s, seed = seed) == .None, "seed %d must open a world", seed) {
			return nil, false
		}
		defer sim_unload(&s)

		cells := make([]Cell, int(view.w) * int(view.h))
		generate(s.world, view, cells)
		return cells, true
	}

	a, a_ok := draw(t, 20260818, view)
	defer delete(a)
	b, b_ok := draw(t, 20260818, view)
	defer delete(b)
	c, c_ok := draw(t, 20260819, view)
	defer delete(c)
	if !a_ok || !b_ok || !c_ok do return

	same := true
	for i in 0 ..< len(a) do if a[i] != b[i] do same = false
	testing.expect(t, same, "the same seed must draw the same world")

	differences := 0
	for i in 0 ..< len(a) do if a[i] != c[i] do differences += 1
	testing.expectf(t, differences > len(a) / 8, "another seed must draw another world, and %d cells of %d differ", differences, len(a))
}

// A drudge stands on the first ground near the wizard that has rock
// over it, and in the Laboratory every such spot is inside a gallery
// room. One pot thrown in there spills over the one thing the room is
// built to show, so the museum keeps nobody.
@(test)
test_the_museum_keeps_nobody :: proc(t: ^testing.T) {
	s: Sim
	if !open_laboratory(t, &s) do return
	defer sim_unload(&s)

	testing.expectf(t, s.drudges.count == 0, "the Laboratory must place no drudge, and it placed %d", s.drudges.count)

	ordinary: Sim
	if !testing.expect(t, sim_load(&ordinary) == .None, "the ordinary world must load") do return
	defer sim_unload(&ordinary)
	testing.expect(t, ordinary.drudges.count == 1, "and the ordinary world must still place one")
}
