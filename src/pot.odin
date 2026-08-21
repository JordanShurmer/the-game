package game

import "core:math"
import "core:testing"
import rl "vendor:raylib"

POT_MAX      :: 8      // pots in the air at once
POT_GRAINS   :: 3      // grains of black powder the pot holds
POT_SPEED    :: 190.0  // cells per second, along the aim
POT_LOB      :: 42.0   // cells per second of lift, so it flies on an arc
POT_GRAVITY  :: PLAYER_GRAVITY
POT_MAX_FALL :: PLAYER_MAX_FALL
POT_REST     :: 40     // ticks between throws
POT_FUSE     :: 90     // ticks the fuse burns before it goes off in the air

// The fuse burns while the pot flies, and a fuse is fire, so the light it
// throws is the light of the Fire material. See docs/lighting.md, "Every
// light is a material".
POT_FUSE_REACH :: 12
POT_FUSE_FALL  :: Light_Fall{open = 176, open_diag = 150, dense = 96, dense_diag = 64}

POT_R :: 2  // cells, the pot as it is drawn

POT_BODY :: rl.Color{48, 40, 32, 255}

POT_FUSE_HALO  :: 3     // the spark drawn at the fuse, a small ember and not a bang
POT_FUSE_BLAZE :: 1
POT_FUSE_PEAK  :: 0.85

// The ember at the fuse is drawn in the colour of the fire burning there,
// over the white core every light in the world has at its heart.
pot_fuse_glow :: proc(table: Material_Table) -> rl.Color {
	return rl_from_argb(table.materials[int(table.fire)].color)
}

// The bang a pot makes is the expulsive force of the Blast material itself,
// which is what the POT_GRAINS grains of black powder it holds throw.
// test_the_pot_carries_the_grains_its_blast_is_made_of holds the two in step.
pot_power :: proc(table: Material_Table) -> u8 {
	return table.materials[int(table.blast)].force
}

Pot :: struct {
	x, y:   f32,
	vx, vy: f32,
	lx, ly: i32,
	fuse:   i16,
	lit:    bool,
	live:   bool,
}
#assert(size_of(Pot) == 28)

Pot_Bag :: struct {
	pots:  [POT_MAX]Pot,
	count: i32,
	rest:  u8,
}

pot_throw :: proc(bag: ^Pot_Bag, p: Player) -> bool {
	if bag.rest > 0 do return false

	cx, cy := player_centre(p)
	dx, dy := player_aim_vector(p.aim)
	reach := f32(PLAYER_BODY_W)*0.5 + 2

	if !pot_launch(bag, f32(cx)+dx*reach, f32(cy)+dy*reach, dx*POT_SPEED+p.vx, dy*POT_SPEED-POT_LOB) do return false

	bag.rest = POT_REST
	return true
}

// The wizard's own hand and a drudge's own hand differ; the slot-finding and
// the placing of a Pot into a bag do not. See docs/drudge.md, "He throws the
// same pot, off his own bag".
pot_launch :: proc(bag: ^Pot_Bag, x, y, vx, vy: f32) -> bool {
	slot := -1
	for i in 0 ..< int(bag.count) {
		if !bag.pots[i].live {
			slot = i
			break
		}
	}
	if slot < 0 {
		if bag.count >= POT_MAX do return false
		slot = int(bag.count)
		bag.count += 1
	}

	bag.pots[slot] = Pot{x = x, y = y, vx = vx, vy = vy, fuse = POT_FUSE, live = true}
	return true
}

pot_step :: proc(bag: ^Pot_Bag, t: Terrain, table: Material_Table) {
	if bag.rest > 0 do bag.rest -= 1

	dt : f32 = 1.0 / PLAYER_TICK_HZ

	for i in 0 ..< int(bag.count) {
		pot := &bag.pots[i]
		if !pot.live do continue

		pot.vy = min(pot.vy+POT_GRAVITY*dt, POT_MAX_FALL)
		pot.fuse -= 1

		broke := pot.fuse <= 0
		if !broke do broke = pot_move(pot, t)
		if broke do pot_break(pot, t, table)
	}
}

@(private = "file")
pot_move :: proc(pot: ^Pot, t: Terrain) -> bool {
	dt : f32 = 1.0 / PLAYER_TICK_HZ
	dx := pot.vx * dt
	dy := pot.vy * dt

	dist := math.sqrt(dx*dx + dy*dy)
	steps := max(i32(math.ceil(dist)), 1)

	sx := dx / f32(steps)
	sy := dy / f32(steps)

	for _ in 0 ..< steps {
		nx := pot.x + sx
		ny := pot.y + sy
		if player_solid_at(t, i32(math.floor(nx)), i32(math.floor(ny))) do return true
		pot.x = nx
		pot.y = ny
	}
	return false
}

// A pot that breaks is spent. What is left of it is the bang the sandbox
// holds: the blast material through the heart of the crater, and the light it
// throws for as long as that material lives.
@(private = "file")
pot_break :: proc(pot: ^Pot, t: Terrain, table: Material_Table) {
	pot.live = false
	if t.sandbox == nil do return

	sx := i32(math.floor(pot.x)) - t.sandbox.origin_x
	sy := i32(math.floor(pot.y)) - t.sandbox.origin_y
	if !sandbox_in_bounds(t.sandbox, sx, sy) do return

	power := pot_power(table)
	sandbox_explode(t.sandbox, table, sx, sy, i32(power), power)
}

@(private = "file")
Pot_Test :: struct {
	table: Material_Table,
	world: World,
	sb:    Sandbox,
}

@(private = "file")
pot_test_setup :: proc(t: ^testing.T) -> (pt: Pot_Test, ok: bool) {
	table, load_ok := load_materials("data/materials.txt")
	if !testing.expect(t, load_ok, "materials must load") do return {}, false

	sb, make_ok := sandbox_make(128, 128, 1)
	if !testing.expect(t, make_ok, "the sandbox must open") do return {}, false

	pot_fill_box(&sb, 0, 0, 127, 127, MATERIAL_AIR)
	return Pot_Test{table = table, world = World{materials = table}, sb = sb}, true
}

@(private = "file")
pot_test_destroy :: proc(pt: ^Pot_Test) {
	sandbox_destroy(&pt.sb)
	destroy_material_table(pt.table)
}

@(private = "file")
pot_fill_box :: proc(sb: ^Sandbox, x0, y0, x1, y1: i32, c: Cell) {
	for y in y0 ..= y1 {
		for x in x0 ..= x1 {
			if !sandbox_in_bounds(sb, x, y) do continue
			sb.cells[sandbox_index(sb, x, y)] = c
		}
	}
}

@(test)
test_a_thrown_pot_flies_and_breaks_on_a_wall_and_leaves_a_crater :: proc(t: ^testing.T) {
	pt, ok := pot_test_setup(t)
	if !ok do return
	defer pot_test_destroy(&pt)

	rock, found := find_material_index(pt.table, "Rock")
	if !testing.expect(t, found, "Rock must exist") do return

	pot_fill_box(&pt.sb, 90, 0, 95, 127, Cell(rock))

	terrain := Terrain{world = pt.world, sandbox = &pt.sb}
	p := Player{x = 20, y = 64, facing = 1, aim = PLAYER_AIM_RIGHT, on_ground = true}

	bag: Pot_Bag
	if !testing.expect(t, pot_throw(&bag, p), "the first throw must succeed") do return

	broke := false
	for _ in 0 ..< POT_FUSE {
		pot_step(&bag, terrain, pt.table)
		if !bag.pots[0].live {
			broke = true
			break
		}
	}
	testing.expect(t, broke, "a pot aimed at a wall must break before its fuse runs out")

	crater := false
	for y in i32(0) ..< 128 {
		for x in i32(90) ..< 96 {
			if int(sandbox_cell(&pt.sb, x, y)) != rock do crater = true
		}
	}
	testing.expect(t, crater, "the blast must have changed some of the wall it broke against")
}

@(test)
test_the_bag_never_holds_more_pots_than_it_can :: proc(t: ^testing.T) {
	p := Player{x = 20, y = 20, facing = 1, aim = PLAYER_AIM_RIGHT}

	bag: Pot_Bag
	for _ in 0 ..< POT_MAX {
		testing.expect(t, pot_throw(&bag, p), "each of the first POT_MAX throws must succeed")
		bag.rest = 0
	}
	testing.expect(t, !pot_throw(&bag, p), "a bag already full must refuse another pot")
	testing.expectf(t, bag.count == POT_MAX, "the bag must not grow past POT_MAX, got %d", bag.count)
}

@(test)
test_the_rest_between_throws_holds :: proc(t: ^testing.T) {
	pt, ok := pot_test_setup(t)
	if !ok do return
	defer pot_test_destroy(&pt)

	rock, found := find_material_index(pt.table, "Rock")
	if !testing.expect(t, found, "Rock must exist") do return
	pot_fill_box(&pt.sb, 40, 0, 45, 127, Cell(rock))

	terrain := Terrain{world = pt.world, sandbox = &pt.sb}
	p := Player{x = 20, y = 20, facing = 1, aim = PLAYER_AIM_RIGHT}

	bag: Pot_Bag
	testing.expect(t, pot_throw(&bag, p), "the first throw must succeed")
	testing.expect(t, !pot_throw(&bag, p), "a second throw right away must be refused")

	for _ in 0 ..< int(POT_REST) - 1 {
		pot_step(&bag, terrain, pt.table)
	}
	testing.expect(t, !pot_throw(&bag, p), "the rest must still be holding one tick early")

	pot_step(&bag, terrain, pt.table)
	testing.expect(t, pot_throw(&bag, p), "the rest must have run out by now")
}

@(test)
test_two_runs_of_the_same_throw_give_the_same_checksum :: proc(t: ^testing.T) {
	run :: proc(t: ^testing.T) -> u64 {
		pt, ok := pot_test_setup(t)
		if !ok do return 0
		defer pot_test_destroy(&pt)

		rock, _ := find_material_index(pt.table, "Rock")
		pot_fill_box(&pt.sb, 90, 0, 95, 127, Cell(rock))

		terrain := Terrain{world = pt.world, sandbox = &pt.sb}
		p := Player{x = 20, y = 64, facing = 1, aim = PLAYER_AIM_RIGHT, on_ground = true}

		bag: Pot_Bag
		pot_throw(&bag, p)
		for _ in 0 ..< 60 do pot_step(&bag, terrain, pt.table)

		return sandbox_checksum(&pt.sb)
	}

	testing.expect(t, run(t) == run(t), "the same throw must give the same checksum both times")
}

@(test)
test_a_pot_that_touches_nothing_goes_off_when_its_fuse_ends :: proc(t: ^testing.T) {
	pt, ok := pot_test_setup(t)
	if !ok do return
	defer pot_test_destroy(&pt)

	terrain := Terrain{world = pt.world, sandbox = &pt.sb}

	bag: Pot_Bag
	bag.count = 1
	bag.pots[0] = Pot{x = 64, y = 64, fuse = 1, live = true}

	pot_step(&bag, terrain, pt.table)
	testing.expect(t, !bag.pots[0].live, "a pot whose fuse ends must break even in open air, and be spent by it")

	lit := false
	for b in pt.sb.bangs.bangs {
		if b.life > 0 do lit = true
	}
	testing.expect(t, lit, "and what is left of it must be a bang the world holds")

	blast := int(sandbox_cell(&pt.sb, 64, 64))
	testing.expectf(
		t, blast == int(pt.table.blast),
		"the cell it went off in must hold the blast material, and it holds %s",
		pt.table.names[blast],
	)
}

@(test)
test_the_pot_carries_the_grains_its_blast_is_made_of :: proc(t: ^testing.T) {
	table, ok := load_materials("data/materials.txt")
	defer destroy_material_table(table)
	if !testing.expect(t, ok, "materials must load") do return

	grains := i32(table.materials[int(table.powder)].force) * POT_GRAINS
	testing.expectf(
		t, i32(pot_power(table)) == grains,
		"the pot holds %d grains of black powder at a force of %d each, so its blast must be %d, and Blast carries %d",
		i32(POT_GRAINS), table.materials[int(table.powder)].force, grains, pot_power(table),
	)
}
