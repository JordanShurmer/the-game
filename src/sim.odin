package game

import testing "check"

MATERIALS_PATH :: "data/materials.txt"
BIOMES_PATH :: "data/biomes.txt"

STARTER_MAP_W :: 16
STARTER_MAP_H :: 16

SANDBOX_DEFAULT_WIDTH  :: 128
SANDBOX_DEFAULT_HEIGHT :: 72
SANDBOX_DEFAULT_DELAY  :: 2

SANDBOX_PLAY_SIZE :: 2048

#assert(
	SANDBOX_PLAY_SIZE <= SANDBOX_MAX_WIDTH && SANDBOX_PLAY_SIZE <= SANDBOX_MAX_HEIGHT,
	"the play sandbox must be a size sandbox_make will build",
)
#assert(SANDBOX_PLAY_SIZE % SANDBOX_CHUNK == 0, "the play sandbox must be a whole number of chunks")

Sim :: struct {
	world:     World,
	player:    Player,
	editor:    Editor,
	tile_edit: Tile_Editor,
	sandbox:   Sandbox,
	queue:     Input_Queue,
	light:     Light,
	flies:      Firefly_Swarm,
	pots:       Pot_Bag,
	drudges:    Drudge_Bag,
	drudge_pots: Pot_Bag,

	follow_player: bool,

	loaded: bool,
}

Sim_Error :: enum u8 {
	None,
	Materials_Not_Found,
	Biomes_Not_Found,
	Tiles_Not_Loaded,
	Images_Not_Loaded,
	Biome_Map_Not_Loaded,
	Air_Not_First,
	Bad_Size,
}

sim_load :: proc(s: ^Sim, materials_path := MATERIALS_PATH, biomes_path := BIOMES_PATH) -> Sim_Error {
	materials, mat_ok := load_materials(materials_path)
	if !mat_ok {
		note("cannot read %s (run from the repo root)", materials_path)
		return .Materials_Not_Found
	}

	air, air_found := find_material_index(materials, "Air")
	if !air_found || air != int(MATERIAL_AIR) {
		note("%s: Air must be the first material", materials_path)
		destroy_material_table(materials)
		return .Air_Not_First
	}

	biomes, err, line := load_biomes(biomes_path, materials)
	if err != .None {
		note("%s: %v at line %d", biomes_path, err, line)
		destroy_material_table(materials)
		return .Biomes_Not_Found
	}

	tiles, tiles_ok := load_or_create_tile_set(biomes, materials)
	if !tiles_ok {
		destroy_biome_table(biomes)
		destroy_material_table(materials)
		return .Tiles_Not_Loaded
	}

	images, images_ok := load_biome_images(biomes, materials)
	if !images_ok {
		destroy_tile_set(tiles)
		destroy_biome_table(biomes)
		destroy_material_table(materials)
		return .Images_Not_Loaded
	}

	bmap, map_ok := load_or_create_biome_map(biomes)
	if !map_ok {
		destroy_image_set(images)
		destroy_tile_set(tiles)
		destroy_biome_table(biomes)
		destroy_material_table(materials)
		return .Biome_Map_Not_Loaded
	}

	s.world = World {
		materials = materials,
		biomes    = biomes,
		biome_map = bmap,
		tiles     = tiles,
		images    = images,
		seed      = biomes.world_seed,
	}

	editor_init(s)

	s.light = light_make(biomes.world_seed)
	s.player = player_spawn(&s.world)

	s.flies = firefly_gather(&s.world, i32(s.player.x), i32(s.player.y))
	s.drudges = drudge_place(&s.world, i32(s.player.x), i32(s.player.y))

	light_follow(&s.light, sim_terrain(s), i32(s.player.x), i32(s.player.y))
	s.loaded = true

	sim_open_sandbox(s, SANDBOX_DEFAULT_WIDTH, SANDBOX_DEFAULT_HEIGHT, 0, 0, 1, SANDBOX_DEFAULT_DELAY)
	return .None
}

sim_unload :: proc(s: ^Sim) {
	if !s.loaded do return
	light_destroy(&s.light)
	sandbox_destroy(&s.sandbox)
	editor_destroy(s)
	destroy_tile_set(s.world.tiles)
	destroy_image_set(s.world.images)
	destroy_biome_map(s.world.biome_map)
	destroy_biome_table(s.world.biomes)
	destroy_material_table(s.world.materials)
	s^ = {}
}

sim_open_sandbox :: proc(s: ^Sim, width, height, origin_x, origin_y: i32, seed: u64, delay: u8) -> Sim_Error {
	sb, ok := sandbox_make(width, height, seed)
	if !ok do return .Bad_Size

	sandbox_fill_from_world(&sb, s.world, origin_x, origin_y)

	sandbox_destroy(&s.sandbox)
	s.sandbox = sb
	input_queue_init(&s.queue, delay)
	return .None
}

sim_enqueue :: proc(s: ^Sim, command: Input_Command, at_tick: i64 = -1) -> (Input_Command, Enqueue_Status) {
	return input_queue_push(&s.queue, s.sandbox.tick, command, at_tick)
}

sim_run :: proc(s: ^Sim, count: int) -> (applied: int) {
	buffer: [INPUT_PER_SLOT]Input_Command

	for _ in 0 ..< count {
		found := input_queue_drain(&s.queue, s.sandbox.tick, buffer[:])
		for i in 0 ..< found {
			sim_apply(s, buffer[i])
		}
		applied += found
		sandbox_step(&s.sandbox, s.world.materials)
	}
	return applied
}

sim_apply :: proc(s: ^Sim, command: Input_Command) {
	switch command.kind {
	case .Noop:
	case .Spawn:
		sandbox_paint(&s.sandbox, s.world.materials, command.x, command.y, i32(command.radius), Cell(command.material))
	case .Erase:
		sandbox_paint(&s.sandbox, s.world.materials, command.x, command.y, i32(command.radius), MATERIAL_AIR)
	case .Ignite:
		sandbox_ignite(&s.sandbox, s.world.materials, command.x, command.y, i32(command.radius))
	case .Explode:
		sandbox_explode(&s.sandbox, s.world.materials, command.x, command.y, i32(command.radius), command_power(command))
	case .Dig:
		sandbox_dig(&s.sandbox, s.world.materials, command.x, command.y, i32(command.radius), command_power(command))
	case .Move:
		sim_step_player(s, command.buttons, .Jump in command.pressed, u8(command.x))
	}
}

command_power :: proc(command: Input_Command) -> u8 {
	return command.material > 255 ? 255 : u8(command.material)
}

sim_material_index :: proc(s: ^Sim, name: string) -> (idx: int, found: bool) {
	return find_material_index(s.world.materials, name)
}

// The world the wizard is standing in: the generated picture, and the
// sandbox over it wherever one is open on him.
sim_terrain :: proc(s: ^Sim) -> Terrain {
	return Terrain{world = &s.world, sandbox = s.follow_player ? &s.sandbox : nil}
}

// Two regions under the village, which is coal on every side and has no
// sky anywhere in the square the light grid covers.
SIM_DARK_X :: -2304
SIM_DARK_Y :: -1536

// Put the wizard on the first standing ground in a box, and move the
// square and the light with him. It answers false when the box holds
// no standing place at all, which is itself worth failing a test over.
sim_stand_near :: proc(s: ^Sim, cx, cy, w, h: i32) -> bool {
	t := Terrain{world = &s.world}
	for dy in i32(0) ..< h {
		for dx in i32(0) ..< w {
			for side in ([2]i32{1, -1}) {
				x := cx + side * dx
				y := cy + dy
				if !player_solid_at(t, x, y) do continue
				if !player_body_clear(t, f32(x), f32(y)) do continue

				s.player.x = f32(x)
				s.player.y = f32(y)
				s.player.vx = 0
				s.player.vy = 0
				sim_follow_player(s)
				return true
			}
		}
	}
	return false
}

// Somewhere dark. The homelands are daylit, so a test about the lamp
// he carries or the trail he leaves has to be run under them: on the
// surface the orb is out, nothing falls from it, and what a grid scan
// finds is the day.
sim_stand_in_the_dark :: proc(s: ^Sim) -> bool {
	return sim_stand_near(s, SIM_DARK_X, SIM_DARK_Y, 240, 480)
}

// At the water's edge of the pond the swarm hangs over, so the light
// square covers the flies a test is about to read.
sim_stand_by_the_swarm :: proc(s: ^Sim) -> bool {
	if s.flies.count == 0 do return false
	f := s.flies.flies[0]
	return sim_stand_near(s, i32(f.home_x), i32(f.home_y) - 8, 160, 80)
}

sim_step_player :: proc(s: ^Sim, held: Player_Input, jump_pressed: bool, aim: u8 = PLAYER_AIM_RIGHT) {
	terrain := sim_terrain(s)

	at := prof_begin()
	player_step(&s.player, terrain, held, jump_pressed, aim)
	if s.follow_player do sim_follow_player(s)
	prof_end(.Player, at)

	at = prof_begin()
	firefly_step(&s.flies)
	prof_end(.Fireflies, at)

	at = prof_begin()
	if .Throw in held do pot_throw(&s.pots, s.player)
	pot_step(&s.pots, terrain, s.world.materials)
	prof_end(.Pots, at)

	at = prof_begin()
	drudge_step(&s.drudges, &s.drudge_pots, terrain, s.player)
	prof_end(.Drudges, at)

	at = prof_begin()
	pot_step(&s.drudge_pots, terrain, s.world.materials)
	prof_end(.Pots, at)

	at = prof_begin()
	light_step(&s.light, terrain, s.player, &s.flies, &s.pots, &s.drudge_pots, &s.drudges)
	prof_end(.Light, at)
}

sim_play_begin :: proc(s: ^Sim) {
	s.follow_player = true
	sim_follow_player(s)
}

sim_follow_player :: proc(s: ^Sim) {
	if !s.follow_player do return

	light_follow(&s.light, sim_terrain(s), i32(s.player.x), i32(s.player.y))

	ox := floor_div(i32(s.player.x), SANDBOX_PLAY_SIZE) * SANDBOX_PLAY_SIZE
	oy := floor_div(i32(s.player.y), SANDBOX_PLAY_SIZE) * SANDBOX_PLAY_SIZE

	already_there := s.sandbox.width == SANDBOX_PLAY_SIZE && s.sandbox.height == SANDBOX_PLAY_SIZE &&
		s.sandbox.origin_x == ox && s.sandbox.origin_y == oy
	if already_there do return

	sim_open_sandbox(s, SANDBOX_PLAY_SIZE, SANDBOX_PLAY_SIZE, ox, oy, s.sandbox.seed, s.queue.delay)
}

load_or_create_tile_set :: proc(biomes: Biome_Table, materials: Material_Table) -> (set: Tile_Set, ok: bool) {
	loaded, result, id := load_tile_set(biomes, materials, true)

	if result.err != .None {
		owner, found := biome_of_tile(biomes, id)
		path := found ? biome_tile_path(biomes, owner, id) : "a tile"
		switch result.err {
		case .Unmatched_Color:
			note(
				"%s: pixel (%d,%d) has color %08X, which no material in %s claims",
				path, result.x, result.y, result.color, MATERIALS_PATH,
			)
		case .Wrong_Size:
			note(
				"%s: the tile is %dx%d, but every tile must be %dx%d",
				path, result.x, result.y, i32(TILE_SIZE), i32(TILE_SIZE),
			)
		case .File_Unreadable:
			note("cannot read or write %s", path)
		case .None:
		}
		return {}, false
	}

	for b, i in biomes.biomes {
		if b.tile_base == TILE_NONE do continue
		conflict := wang_find_conflict(loaded, b)
		if !conflict.found do continue

		note(
			"%s: %s and %s disagree at cell (%d,%d), where the edge color they share says they must not. Open the set and press N.",
			biomes.names[i],
			biome_tile_path(biomes, Biome_Id(i), conflict.a),
			biome_tile_path(biomes, Biome_Id(i), conflict.b),
			conflict.x, conflict.y,
		)
	}
	return loaded, true
}

load_biome_images :: proc(biomes: Biome_Table, materials: Material_Table) -> (images: [][]Cell, ok: bool) {
	loaded, result, bad_biome := load_image_set(biomes, materials)
	if result.err != .None {
		path := bad_biome != BIOME_EMPTY ? biomes.image_paths[bad_biome] : "an image"
		cpp := biomes.cells_per_pixel
		switch result.err {
		case .Unmatched_Color:
			note(
				"%s: pixel (%d,%d) has color %08X, which no material in %s claims",
				path, result.x, result.y, result.color, MATERIALS_PATH,
			)
		case .Wrong_Size:
			note(
				"%s: the image is %dx%d, but it must be %dx%d",
				path, result.x, result.y, cpp, cpp,
			)
		case .File_Unreadable:
			note("cannot read %s", path)
		case .None:
		}
		return {}, false
	}
	return loaded, true
}

load_or_create_biome_map :: proc(biomes: Biome_Table) -> (m: Biome_Map, ok: bool) {
	path := biomes.map_image_path

	if file_exists(path) {
		loaded, result := load_biome_map_png(path, biomes)
		if result.err == .Unmatched_Color {
			note(
				"%s: pixel (%d,%d) has color %08X, which no biome in %s claims",
				path, result.x, result.y, result.color, BIOMES_PATH,
			)
			return {}, false
		}
		if result.err != .None {
			note("%s: %v", path, result.err)
			return {}, false
		}
		return loaded, true
	}

	m = make_starter_biome_map(biomes)
	if !save_biome_map_png(m, biomes, path) {
		note("cannot write %s", path)
		destroy_biome_map(m)
		return {}, false
	}
	note("wrote a starter map to %s", path)
	return m, true
}

make_starter_biome_map :: proc(biomes: Biome_Table) -> Biome_Map {
	m := make_biome_map(STARTER_MAP_W, STARTER_MAP_H)

	id_of :: proc(biomes: Biome_Table, name: string) -> Biome_Id {
		idx, found := find_biome_index(biomes, name)
		assert(found, "the starter map names a biome that data/biomes.txt does not define")
		return Biome_Id(idx)
	}

	sky := id_of(biomes, "Sky")
	mine := id_of(biomes, "Coalmine")
	sand := id_of(biomes, "Sandcave")
	lake := id_of(biomes, "Lake")
	oil := id_of(biomes, "Oilfield")
	acid := id_of(biomes, "Acidpool")
	magma := id_of(biomes, "Magma")
	vault := id_of(biomes, "Vault")
	deep := id_of(biomes, "Deep_Rock")

	band :: proc(m: Biome_Map, y0, y1: i32, id: Biome_Id) {
		for y in y0 ..= y1 {
			for x in i32(0) ..< m.width do biome_map_set(m, x, y, id)
		}
	}
	blob :: proc(m: Biome_Map, x0, y0, x1, y1: i32, id: Biome_Id) {
		for y in y0 ..= y1 {
			for x in x0 ..= x1 do biome_map_set(m, x, y, id)
		}
	}

	band(m, 0, 2, sky)
	band(m, 3, 6, mine)
	band(m, 7, 9, sand)
	band(m, 10, 12, oil)
	band(m, 13, 15, deep)

	blob(m, 10, 7, 13, 8, lake)
	blob(m, 2, 11, 4, 12, acid)
	blob(m, 6, 14, 9, 15, magma)
	blob(m, 13, 13, 13, 13, vault)

	return m
}

@(private = "file")
new_sim :: proc(t: ^testing.T) -> Sim {
	s: Sim
	err := sim_load(&s)
	testing.expect(t, err == .None, "the simulation must load")
	return s
}

@(test)
test_sim_opens_a_sandbox_on_the_world :: proc(t: ^testing.T) {
	s := new_sim(t)
	defer sim_unload(&s)

	testing.expect(t, s.sandbox.width == SANDBOX_DEFAULT_WIDTH)
	testing.expect(t, s.sandbox.height == SANDBOX_DEFAULT_HEIGHT)
	testing.expect(t, s.sandbox.tick == 0)

	for y in i32(0) ..< s.sandbox.height {
		for x in i32(0) ..< s.sandbox.width {
			expected := world_cell_at(s.world, s.sandbox.origin_x + x, s.sandbox.origin_y + y)
			testing.expectf(
				t,
				sandbox_cell(&s.sandbox, x, y) == expected,
				"the sandbox must match the world at %d,%d",
				x, y,
			)
		}
	}
}

@(test)
test_command_waits_for_its_tick :: proc(t: ^testing.T) {
	s := new_sim(t)
	defer sim_unload(&s)

	sandbox_paint(&s.sandbox, s.world.materials, 0, 0, 1000, MATERIAL_AIR)

	sand, _ := sim_material_index(&s, "Sand")
	out, status := sim_enqueue(&s, Input_Command{kind = .Spawn, x = 16, y = 0, material = u16(sand)})

	testing.expect(t, status == .Accepted)
	testing.expect(t, out.tick == 2, "the default delay must hold the command for two ticks")

	sim_run(&s, 2)
	empty := true
	for c in s.sandbox.cells {
		if c != MATERIAL_AIR do empty = false
	}
	testing.expect(t, empty, "the sandbox must stay empty until the command runs")

	testing.expect(t, sim_run(&s, 1) == 1, "tick 2 must apply the command")

	filled := false
	for c in s.sandbox.cells {
		if c != MATERIAL_AIR do filled = true
	}
	testing.expect(t, filled, "the sand must exist after the command runs")
}

@(test)
test_same_commands_give_the_same_sandbox :: proc(t: ^testing.T) {
	run :: proc(t: ^testing.T) -> u64 {
		s := new_sim(t)
		defer sim_unload(&s)
		sim_open_sandbox(&s, 48, 32, 0, 0, 777, 2)

		sand, _ := sim_material_index(&s, "Sand")
		water, _ := sim_material_index(&s, "Water")

		for step in 0 ..< 90 {
			if step % 7 == 0 {
				sim_enqueue(&s, Input_Command{kind = .Spawn, x = 24, y = 0, radius = 2, material = u16(sand)})
			}
			if step % 11 == 0 {
				sim_enqueue(&s, Input_Command{kind = .Spawn, x = 10, y = 0, radius = 1, material = u16(water), source = 1})
			}
			if step == 50 {
				sim_enqueue(&s, Input_Command{kind = .Ignite, x = 24, y = 20, radius = 3})
			}
			sim_run(&s, 1)
		}
		return sandbox_checksum(&s.sandbox)
	}

	testing.expect(t, run(t) == run(t), "the same seed and commands must give the same checksum")
}

@(test)
test_arrival_order_does_not_change_the_sandbox :: proc(t: ^testing.T) {
	build :: proc(t: ^testing.T, swap: bool) -> u64 {
		s := new_sim(t)
		defer sim_unload(&s)
		sim_open_sandbox(&s, 24, 24, 0, 0, 99, 1)

		sand, _ := sim_material_index(&s, "Sand")
		rock, _ := sim_material_index(&s, "Rock")

		first := Input_Command{kind = .Spawn, x = 12, y = 12, radius = 3, material = u16(sand), source = 0}
		second := Input_Command{kind = .Spawn, x = 12, y = 12, radius = 3, material = u16(rock), source = 1}

		if swap {
			sim_enqueue(&s, second)
			sim_enqueue(&s, first)
		} else {
			sim_enqueue(&s, first)
			sim_enqueue(&s, second)
		}
		sim_run(&s, 5)
		return sandbox_checksum(&s.sandbox)
	}

	testing.expect(t, build(t, false) == build(t, true), "arrival order must not matter")
}

@(test)
test_a_command_for_a_passed_tick_still_runs :: proc(t: ^testing.T) {
	s := new_sim(t)
	defer sim_unload(&s)

	sim_run(&s, 10)
	sand, _ := sim_material_index(&s, "Sand")

	out, status := sim_enqueue(&s, Input_Command{kind = .Spawn, x = 16, y = 0, material = u16(sand)}, 4)
	testing.expect(t, status == .Late, "tick 4 has already run")
	testing.expect(t, out.tick == 10, "the command must move to the next tick")
	testing.expect(t, sim_run(&s, 1) == 1, "the late command must still run")
}

@(test)
test_a_tile_edit_reaches_the_sandbox :: proc(t: ^testing.T) {
	s := new_sim(t)
	defer sim_unload(&s)

	mine, found := find_biome_index(s.world.biomes, "Coalmine")
	if !testing.expect(t, found, "Coalmine must exist") do return
	b := s.world.biomes.biomes[mine]
	if !testing.expect(t, b.tile_base != TILE_NONE, "Coalmine must own a set") do return

	cpp := s.world.biomes.cells_per_pixel
	ox := (0 - s.world.biomes.origin_pixel_x) * cpp
	oy := (4 - s.world.biomes.origin_pixel_y) * cpp  // row 4: coal, and no homeland over it
	sim_open_sandbox(&s, 128, 128, ox, oy, 1, 0)

	gold, _ := sim_material_index(&s, "Gold")
	for k in 0 ..< wang_set_size(b) {
		tile_fill(s.world.tiles, b.tile_base + Tile_Id(k), Cell(gold))
	}
	sandbox_fill_from_world(&s.sandbox, s.world, ox, oy)

	counts := make([]int, len(s.world.materials.materials))
	defer delete(counts)
	sandbox_census(&s.sandbox, counts)
	testing.expect(t, counts[gold] == 128*128, "the painted set must fill the sandbox")
}

@(test)
test_sim_load_leaves_following_off_so_a_hand_opened_sandbox_stays_put :: proc(t: ^testing.T) {
	s := new_sim(t)
	defer sim_unload(&s)

	testing.expect(t, !s.follow_player, "sim_load must not turn on following: only sim_play_begin does")
	testing.expect(
		t, s.sandbox.origin_x == 0 && s.sandbox.origin_y == 0,
		"sim_load must still open its sandbox at the world origin, unmoved by a wizard it also spawns",
	)
}

@(test)
test_sim_play_begin_opens_the_sandbox_on_the_players_square :: proc(t: ^testing.T) {
	s := new_sim(t)
	defer sim_unload(&s)

	sim_play_begin(&s)

	want_x := floor_div(i32(s.player.x), SANDBOX_PLAY_SIZE) * SANDBOX_PLAY_SIZE
	want_y := floor_div(i32(s.player.y), SANDBOX_PLAY_SIZE) * SANDBOX_PLAY_SIZE

	testing.expect(t, s.follow_player, "sim_play_begin must turn following on")
	testing.expectf(
		t, s.sandbox.width == SANDBOX_PLAY_SIZE && s.sandbox.height == SANDBOX_PLAY_SIZE,
		"the play sandbox must be SANDBOX_PLAY_SIZE square, got %dx%d", s.sandbox.width, s.sandbox.height,
	)
	testing.expectf(
		t, s.sandbox.origin_x == want_x && s.sandbox.origin_y == want_y,
		"the sandbox must snap to the square he spawned in, got %d,%d want %d,%d",
		s.sandbox.origin_x, s.sandbox.origin_y, want_x, want_y,
	)
	testing.expectf(
		t,
		i32(s.player.x) >= s.sandbox.origin_x &&
		i32(s.player.x) < s.sandbox.origin_x + SANDBOX_PLAY_SIZE &&
		i32(s.player.y) >= s.sandbox.origin_y &&
		i32(s.player.y) < s.sandbox.origin_y + SANDBOX_PLAY_SIZE,
		"and he must be inside it: he is at %v,%v and it starts at %d,%d",
		s.player.x, s.player.y, s.sandbox.origin_x, s.sandbox.origin_y,
	)
}

@(test)
test_sim_follow_player_re_snaps_the_sandbox_when_he_leaves_the_square :: proc(t: ^testing.T) {
	s := new_sim(t)
	defer sim_unload(&s)
	sim_play_begin(&s)
	before_x := s.sandbox.origin_x

	s.player.x += f32(SANDBOX_PLAY_SIZE)
	sim_follow_player(&s)

	want_x := floor_div(i32(s.player.x), SANDBOX_PLAY_SIZE) * SANDBOX_PLAY_SIZE
	testing.expectf(
		t, s.sandbox.origin_x == want_x,
		"leaving the square must re-snap the sandbox origin, got %d want %d", s.sandbox.origin_x, want_x,
	)
	testing.expect(t, s.sandbox.origin_x != before_x, "the origin must actually have moved")
}

@(test)
test_sim_follow_player_holds_across_a_region_border :: proc(t: ^testing.T) {
	s := new_sim(t)
	defer sim_unload(&s)
	sim_play_begin(&s)

	cpp := s.world.biomes.cells_per_pixel
	room := testing.expectf(
		t, cpp < SANDBOX_PLAY_SIZE,
		"this test means nothing unless a region (%d) is smaller than the sandbox (%d)",
		cpp, SANDBOX_PLAY_SIZE,
	)
	if !room do return

	before_x := s.sandbox.origin_x
	before_tick := s.sandbox.tick

	s.player.x = f32(before_x + cpp)
	sim_follow_player(&s)

	testing.expectf(
		t, s.sandbox.origin_x == before_x,
		"crossing a region border must not move the sandbox, got %d want %d", s.sandbox.origin_x, before_x,
	)
	testing.expect(
		t, s.sandbox.tick == before_tick,
		"and must not re-open it, which would reset the tick and forget what he dug",
	)
}

@(test)
test_a_move_command_through_the_queue_matches_the_direct_path :: proc(t: ^testing.T) {
	Recorded :: struct {
		held:    Player_Input,
		pressed: Player_Input,
	}
	inputs := []Recorded {
		{{.Right}, {}}, {{.Right}, {}}, {{.Right, .Run}, {}},
		{{.Right, .Run, .Jump}, {.Jump}}, {{.Jump}, {}}, {{.Jump}, {}},
		{{}, {}}, {{.Left}, {}},
	}

	direct := new_sim(t)
	defer sim_unload(&direct)
	for step in inputs {
		sim_step_player(&direct, step.held, .Jump in step.pressed)
	}

	queued := new_sim(t)
	defer sim_unload(&queued)
	for step, i in inputs {
		cmd := Input_Command{kind = .Move, buttons = step.held, pressed = step.pressed}
		sim_enqueue(&queued, cmd, i64(i))
	}
	sim_run(&queued, len(inputs))

	testing.expectf(
		t, direct.player.x == queued.player.x && direct.player.y == queued.player.y,
		"a Move command through the queue must move him exactly as the direct path does, got (%v,%v) vs (%v,%v)",
		queued.player.x, queued.player.y, direct.player.x, direct.player.y,
	)
}
