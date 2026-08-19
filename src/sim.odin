package game

import "core:fmt"
import "core:os"
import "core:testing"

/*
The game state, with no window in it.

A Sim holds everything the game knows: the authored world, the state
of both editors, the sandbox that runs physics, and the input queue
that feeds it. It holds nothing that needs a screen.

Two programs own one of these. The game window wraps it in an App and
adds a camera and a texture. The MCP server drives it with no camera
at all. Both call the same procedures, so a model and a mouse cannot
build different worlds.

A tick has two parts and always in this order:

  1. Take the commands of the tick from the queue and apply them.
  2. Step the sandbox.

Nothing else writes to the sandbox. That single rule is what makes a
run repeatable: the sandbox is a function of the seed, the region it
was filled from, and the command list.
*/

MATERIALS_PATH :: "data/materials.txt"
BIOMES_PATH :: "data/biomes.txt"

// The map starts this big when there is no image on disk yet.
STARTER_MAP_W :: 16
STARTER_MAP_H :: 16

SANDBOX_DEFAULT_WIDTH  :: 128
SANDBOX_DEFAULT_HEIGHT :: 72
SANDBOX_DEFAULT_DELAY  :: 2

// See docs/physics.md, "The wizard meets the sandbox". One region, in
// the shipped data: cells_per_pixel is 512, so a sandbox this size
// covers exactly the region he stands in.
SANDBOX_PLAY_SIZE :: 512

Sim :: struct {
	world:     World,       // the authored world: materials, biomes, map, tiles
	player:    Player,      // the wizard; see docs/player.md
	editor:    Editor,      // biome map editing state
	tile_edit: Tile_Editor, // tile editing state
	sandbox:   Sandbox,     // the rectangle that runs physics
	queue:     Input_Queue, // commands waiting for their tick

	// Whether the sandbox follows the wizard's region. sim_load leaves
	// this false, so the MCP server and every test that opens a sandbox
	// by hand keep exactly the sandbox they asked for; only a caller
	// that says sim_play_begin gets the sandbox re-snapped under him.
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

/*
Load every data file and open a sandbox on the world.

Each failure says what is wrong and where, because a half-loaded world
is worse than no world.
*/
sim_load :: proc(s: ^Sim, materials_path := MATERIALS_PATH, biomes_path := BIOMES_PATH) -> Sim_Error {
	materials, mat_ok := load_materials(materials_path)
	if !mat_ok {
		fmt.eprintfln("cannot read %s (run from the repo root)", materials_path)
		return .Materials_Not_Found
	}

	// A sandbox clears to zeroed memory, so Air must be index 0.
	air, air_found := find_material_index(materials, "Air")
	if !air_found || air != int(MATERIAL_AIR) {
		fmt.eprintfln("%s: Air must be the first material", materials_path)
		destroy_material_table(materials)
		return .Air_Not_First
	}

	biomes, err, line := load_biomes(biomes_path, materials)
	if err != .None {
		fmt.eprintfln("%s: %v at line %d", biomes_path, err, line)
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

	// Beside a hole, not in it: world_find_spawn scans the shipped map
	// for the mouth into the caves and stands him clear of its lip. He
	// owns no allocation, so nothing here needs a matching teardown.
	s.player = player_spawn(s.world)
	s.loaded = true

	// Open a sandbox on the world origin, so a client can run physics
	// without setting one up first.
	sim_open_sandbox(s, SANDBOX_DEFAULT_WIDTH, SANDBOX_DEFAULT_HEIGHT, 0, 0, 1, SANDBOX_DEFAULT_DELAY)
	return .None
}

sim_unload :: proc(s: ^Sim) {
	if !s.loaded do return
	sandbox_destroy(&s.sandbox)
	editor_destroy(s)
	destroy_tile_set(s.world.tiles)
	destroy_image_set(s.world.images)
	destroy_biome_map(s.world.biome_map)
	destroy_biome_table(s.world.biomes)
	destroy_material_table(s.world.materials)
	s^ = {}
}

/*
Open a sandbox on a rectangle of the authored world.

The cells come from the generator, so the physics starts from what the
player would walk into. This is the join between the two halves of the
game: paint a tile, open a sandbox on a region of that biome, and the
paint is what falls.
*/
sim_open_sandbox :: proc(s: ^Sim, width, height, origin_x, origin_y: i32, seed: u64, delay: u8) -> Sim_Error {
	sb, ok := sandbox_make(width, height, seed)
	if !ok do return .Bad_Size

	sandbox_fill_from_world(&sb, s.world, origin_x, origin_y)

	sandbox_destroy(&s.sandbox)
	s.sandbox = sb
	input_queue_init(&s.queue, delay)
	return .None
}

/*
Refill the sandbox from the world, keeping its size and its place.

The editors change the world under a running sandbox. This is how a
client sees an edit reach the physics: paint, refill, run.
*/
sim_refill_sandbox :: proc(s: ^Sim) {
	sandbox_fill_from_world(&s.sandbox, s.world, s.sandbox.origin_x, s.sandbox.origin_y)
	s.sandbox.tick = 0
	s.sandbox.rng = sandbox_seed_state(s.sandbox.seed)
	input_queue_init(&s.queue, s.queue.delay)
}

// Put a command in the queue for a later tick. It does not run yet.
sim_enqueue :: proc(s: ^Sim, command: Input_Command, at_tick: i64 = -1) -> (Input_Command, Enqueue_Status) {
	return input_queue_push(&s.queue, s.sandbox.tick, command, at_tick)
}

/*
Run `count` ticks.

The commands of a tick run before the sandbox steps, so a command
placed on tick N sees the world as it was at the end of tick N-1.
*/
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
		// The same single implementation the window's direct path
		// calls: docs/physics.md's "one path for a hand and a model."
		sim_step_player(s, command.buttons, .Jump in command.pressed)
	}
}

/*
The power an Explode or a Dig carries.

Both ride the `material` field, because it is the spare u16 and a
power is not a material anywhere else. A power is a u8, so a caller
that writes a larger number gets the largest power rather than a
number folded round to a small one.
*/
command_power :: proc(command: Input_Command) -> u8 {
	return command.material > 255 ? 255 : u8(command.material)
}

sim_material_index :: proc(s: ^Sim, name: string) -> (idx: int, found: bool) {
	return find_material_index(s.world.materials, name)
}

/*
One whole tick of the wizard.

He is not on the Input_Queue (docs/player.md says why: held movement
keys through the queue's delay is input lag, not fairness), so this is
a second, simpler path into the Sim, taken directly rather than
through sim_apply. The window keeps the fixed-step accumulator and
calls this a whole number of times per frame; the Move command above
calls it too, so both paths still run the one player_step.

The Terrain built here is the whole of the join (docs/physics.md, "The
wizard meets the sandbox"): a sandbox pointer only when s.follow_player
says he is standing on the running physics, nil otherwise, so a caller
that never asked to follow gets the same World-only collision the
wizard always had. Following also re-snaps the sandbox after the
move, in case this tick carried him over a region border.
*/
sim_step_player :: proc(s: ^Sim, held: Player_Input, jump_pressed: bool) {
	terrain := Terrain{world = s.world, sandbox = s.follow_player ? &s.sandbox : nil}
	player_step(&s.player, terrain, held, jump_pressed)
	if s.follow_player do sim_follow_player(s)
}

/*
Start following: open the play sandbox on the region the wizard is
already standing in, and turn on the flag that keeps it there.

sim_load does not call this. It opens its own sandbox at the world
origin for the MCP server and for every test that wants a sandbox of
its own choosing, and follow_player defaults to false, so none of
those callers see their sandbox move out from under them. Only a
caller that wants the play experience asks for it.
*/
sim_play_begin :: proc(s: ^Sim) {
	s.follow_player = true
	sim_follow_player(s)
}

/*
Re-snap the play sandbox to the region the wizard is standing in, if
it has moved.

The sandbox origin is the region's own corner: floor_div, not
truncating division, because a region can sit on the negative side of
zero. SANDBOX_PLAY_SIZE is fixed at 512 regardless of cells_per_pixel;
it is one region only because the shipped data's cells_per_pixel is
also 512. A biome ever set with a larger cells_per_pixel cannot be
followed at all, because SANDBOX_MAX_WIDTH bounds how big a sandbox
can open: this checks that first and leaves the sandbox as it is
rather than asserting, the graceful fallback docs/physics.md asks for.

What this costs, said plainly: a region he leaves and returns to is
regenerated from the world, not restored from what he changed in it.
That is the documented limit of this rung (docs/physics.md), not a bug
— the rung that fixes it is a store of touched regions, keyed by
region coordinate, which this phase does not build. A re-snap also
runs through sim_open_sandbox, which resets the input queue the same
way any other call to it always has; a border crossing is rare enough,
and the loss small enough, that this phase accepts it rather than
adding a second way to open a sandbox that preserves one.
*/
sim_follow_player :: proc(s: ^Sim) {
	if !s.follow_player do return

	cpp := s.world.biomes.cells_per_pixel
	if cpp > SANDBOX_MAX_WIDTH do return // cannot fit one region in a sandbox at all

	ox := floor_div(i32(s.player.x), cpp) * cpp
	oy := floor_div(i32(s.player.y), cpp) * cpp

	already_there := s.sandbox.width == SANDBOX_PLAY_SIZE && s.sandbox.height == SANDBOX_PLAY_SIZE &&
		s.sandbox.origin_x == ox && s.sandbox.origin_y == oy
	if already_there do return

	sim_open_sandbox(s, SANDBOX_PLAY_SIZE, SANDBOX_PLAY_SIZE, ox, oy, s.sandbox.seed, s.queue.delay)
}

// ------------------------------------------------------------
// Loading the world files
// ------------------------------------------------------------

/*
Read every authored tile, and write a flat one for any tile a set
names but nobody has painted yet.

This is the same bargain load_or_create_biome_map makes: a fresh
checkout opens on a world you can see, and the files it writes are the
files the editor saves. A biome that has just been given
`generator = wang` gets a complete flat set, which draws exactly the
world its old flat fill drew until somebody paints into it.

A set that disagrees with itself still loads. It came from a pixel
editor that knows nothing of the seam rule, and the way to fix it is
to open it and press N, not to refuse to start.
*/
load_or_create_tile_set :: proc(biomes: Biome_Table, materials: Material_Table) -> (set: Tile_Set, ok: bool) {
	loaded, result, id := load_tile_set(biomes, materials, true)

	if result.err != .None {
		owner, found := biome_of_tile(biomes, id)
		path := found ? biome_tile_path(biomes, owner, id) : "a tile"
		switch result.err {
		case .Unmatched_Color:
			fmt.eprintfln(
				"%s: pixel (%d,%d) has color %08X, which no material in %s claims",
				path, result.x, result.y, result.color, MATERIALS_PATH,
			)
		case .Wrong_Size:
			fmt.eprintfln(
				"%s: the tile is %dx%d, but every tile must be %dx%d",
				path, result.x, result.y, i32(TILE_SIZE), i32(TILE_SIZE),
			)
		case .File_Unreadable:
			fmt.eprintfln("cannot read or write %s", path)
		case .None:
		}
		return {}, false
	}

	// Say so once, at load, rather than letting the author find the
	// broken seam in the world.
	for b, i in biomes.biomes {
		if b.tile_base == TILE_NONE do continue
		conflict := wang_find_conflict(loaded, b)
		if !conflict.found do continue

		fmt.eprintfln(
			"%s: %s and %s disagree at cell (%d,%d), where the edge color they share says they must not. Open the set and press N.",
			biomes.names[i],
			biome_tile_path(biomes, Biome_Id(i), conflict.a),
			biome_tile_path(biomes, Biome_Id(i), conflict.b),
			conflict.x, conflict.y,
		)
	}
	return loaded, true
}

/*
Read every picture an image biome names.

Unlike a tile set, there is no flat fallback to fall back to: the
picture is the whole region, so a missing or wrong-sized file is a
hard stop, reported the same way a bad tile is.
*/
load_biome_images :: proc(biomes: Biome_Table, materials: Material_Table) -> (images: [][]Cell, ok: bool) {
	loaded, result, bad_biome := load_image_set(biomes, materials)
	if result.err != .None {
		path := bad_biome != BIOME_EMPTY ? biomes.image_paths[bad_biome] : "an image"
		cpp := biomes.cells_per_pixel
		switch result.err {
		case .Unmatched_Color:
			fmt.eprintfln(
				"%s: pixel (%d,%d) has color %08X, which no material in %s claims",
				path, result.x, result.y, result.color, MATERIALS_PATH,
			)
		case .Wrong_Size:
			fmt.eprintfln(
				"%s: the image is %dx%d, but it must be %dx%d",
				path, result.x, result.y, cpp, cpp,
			)
		case .File_Unreadable:
			fmt.eprintfln("cannot read %s", path)
		case .None:
		}
		return {}, false
	}
	return loaded, true
}

/*
Read the map image, or paint a starter map and write it. A new
checkout then opens on a world you can see, and the file it writes is
the same file the editor saves.
*/
load_or_create_biome_map :: proc(biomes: Biome_Table) -> (m: Biome_Map, ok: bool) {
	path := biomes.map_image_path

	if os.exists(path) {
		loaded, result := load_biome_map_png(path, biomes)
		if result.err == .Unmatched_Color {
			fmt.eprintfln(
				"%s: pixel (%d,%d) has color %08X, which no biome in %s claims",
				path, result.x, result.y, result.color, BIOMES_PATH,
			)
			return {}, false
		}
		if result.err != .None {
			fmt.eprintfln("%s: %v", path, result.err)
			return {}, false
		}
		return loaded, true
	}

	m = make_starter_biome_map(biomes)
	if !save_biome_map_png(m, biomes, path) {
		fmt.eprintfln("cannot write %s", path)
		destroy_biome_map(m)
		return {}, false
	}
	fmt.eprintfln("wrote a starter map to %s", path)
	return m, true
}

/*
A layered starter world: sky over a mine, sand and a lake below it,
then oil, and deep rock at the bottom. Every pixel is painted, so the
map is connected and can be saved as it is.
*/
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

// ------------------------------------------------------------
// Tests (run with: odin test src  from repo root)
// ------------------------------------------------------------

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

	// The sandbox is filled from the generator, so every cell must
	// agree with what the world says is there.
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

	// A bare sandbox, so the world behind does not hide the change.
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
	// This is the check old network code ran every frame. Two machines
	// with the same seed and the same input must agree.
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
	// Two senders paint the same tick in a different arrival order. The
	// queue sorts them, so both sandboxes must match.
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
	// The whole join in one test: paint a tile, refill the sandbox from
	// the world, and the paint is in the physics.
	s := new_sim(t)
	defer sim_unload(&s)

	mine, found := find_biome_index(s.world.biomes, "Coalmine")
	if !testing.expect(t, found, "Coalmine must exist") do return
	b := s.world.biomes.biomes[mine]
	if !testing.expect(t, b.tile_base != TILE_NONE, "Coalmine must own a set") do return

	// A region the mine owns. Map pixel (0,3) is Coalmine in the
	// starter map, so it starts at world cell (0 - origin) * cpp. The
	// sandbox is wider than one tile, so it reads several squares of
	// the lattice and the whole set has to be painted.
	cpp := s.world.biomes.cells_per_pixel
	ox := (0 - s.world.biomes.origin_pixel_x) * cpp
	oy := (3 - s.world.biomes.origin_pixel_y) * cpp
	sim_open_sandbox(&s, 128, 128, ox, oy, 1, 0)

	gold, _ := sim_material_index(&s, "Gold")
	for k in 0 ..< wang_set_size(b) {
		tile_fill(s.world.tiles, b.tile_base + Tile_Id(k), Cell(gold))
	}
	sim_refill_sandbox(&s)

	counts := make([]int, len(s.world.materials.materials))
	defer delete(counts)
	sandbox_census(&s.sandbox, counts)
	testing.expect(t, counts[gold] == 128*128, "the painted set must fill the sandbox")
}

// ------------------------------------------------------------
// The join: sim_play_begin, sim_follow_player, and the Move command
// ------------------------------------------------------------

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
test_sim_play_begin_opens_the_sandbox_on_the_players_region :: proc(t: ^testing.T) {
	s := new_sim(t)
	defer sim_unload(&s)

	sim_play_begin(&s)

	cpp := s.world.biomes.cells_per_pixel
	want_x := floor_div(i32(s.player.x), cpp) * cpp
	want_y := floor_div(i32(s.player.y), cpp) * cpp

	testing.expect(t, s.follow_player, "sim_play_begin must turn following on")
	testing.expectf(
		t, s.sandbox.width == SANDBOX_PLAY_SIZE && s.sandbox.height == SANDBOX_PLAY_SIZE,
		"the play sandbox must be one region, got %dx%d", s.sandbox.width, s.sandbox.height,
	)
	testing.expectf(
		t, s.sandbox.origin_x == want_x && s.sandbox.origin_y == want_y,
		"the sandbox must snap to the region he spawned in, got %d,%d want %d,%d",
		s.sandbox.origin_x, s.sandbox.origin_y, want_x, want_y,
	)
}

/*
Crossing a region border re-snaps the sandbox origin to the new
region. This carries him a whole region to the side directly, rather
than walking him there tick by tick, because the border is what the
test is about, not the walk that reaches it.
*/
@(test)
test_sim_follow_player_re_snaps_the_sandbox_at_a_region_border :: proc(t: ^testing.T) {
	s := new_sim(t)
	defer sim_unload(&s)
	sim_play_begin(&s)
	before_x := s.sandbox.origin_x

	cpp := s.world.biomes.cells_per_pixel
	s.player.x += f32(cpp)
	sim_follow_player(&s)

	want_x := floor_div(i32(s.player.x), cpp) * cpp
	testing.expectf(
		t, s.sandbox.origin_x == want_x,
		"crossing a region border must re-snap the sandbox origin, got %d want %d", s.sandbox.origin_x, want_x,
	)
	testing.expect(t, s.sandbox.origin_x != before_x, "the origin must actually have moved")
}

/*
A Move command through the queue must move him exactly as the direct
path does, given the same inputs. This is the check docs/player.md
asks for: "one path for a hand and a model" only holds if both paths
call the same player_step and reach the same position.
*/
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
