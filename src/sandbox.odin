package game

import "core:mem"
import "core:slice"
import "core:testing"

/*
The sandbox: a bounded rectangle of the world that runs physics.

The generator and the sandbox answer two different questions. The
generator says what a place is made of. The sandbox says what that
place does next.

They meet at one type. `generate` writes `[]Cell`, and a sandbox is a
`[]Cell` plus the little state that physics needs, so a region of the
authored world drops straight into one. Paint a tile, generate the
region it describes, and watch the sand in it fall.

The step is deterministic. The same seed and the same commands always
give the same result, which is what lets the input queue replay a
session and lets a test compare one checksum instead of a picture.

The y axis points down, the same way it does in the world.
*/

SANDBOX_MAX_WIDTH  :: 1024
SANDBOX_MAX_HEIGHT :: 1024

// Index 0 of the material table is Air. A sandbox clears to zeroed
// memory, so Air must be the value that zero means. sim_init checks it.
MATERIAL_AIR :: Cell(0)

/*
Parallel arrays, not a fat cell.

`cells` alone is what the generator writes and what a renderer reads,
so it stays a plain array of material ids with nothing else in it.
The physics state sits beside it and is touched only by the step.
*/
Sandbox :: struct {
	cells:    []Cell, // material id per cell, as the generator writes it
	lifetime: []i16,  // ticks left before the cell changes; -1 never changes
	moved:    []bool, // one flag per cell, cleared at the start of each step
	width:    i32,
	height:   i32,

	// Where this rectangle sits in the unbounded world. A sandbox
	// filled from the generator remembers where it came from, so the
	// map coordinates a client sees mean the same thing everywhere.
	origin_x: i32,
	origin_y: i32,

	tick:     u64, // the next tick to run
	seed:     u64,
	rng:      u64,
}

// How a cell is allowed to enter the target cell.
Move_Rule :: enum u8 {
	Into_Air, // only an empty target
	Sink,     // an empty target, or a lighter target that can flow
	Rise,     // an empty target, or a heavier target that can flow
}

sandbox_make :: proc(width, height: i32, seed: u64, allocator := context.allocator) -> (sb: Sandbox, ok: bool) {
	if width <= 0 || height <= 0 do return {}, false
	if width > SANDBOX_MAX_WIDTH || height > SANDBOX_MAX_HEIGHT do return {}, false

	count := int(width) * int(height)
	sb.cells = make([]Cell, count, allocator)
	sb.lifetime = make([]i16, count, allocator)
	sb.moved = make([]bool, count, allocator)
	sb.width = width
	sb.height = height
	sb.seed = seed
	sb.rng = sandbox_seed_state(seed)
	return sb, true
}

sandbox_destroy :: proc(sb: ^Sandbox, allocator := context.allocator) {
	delete(sb.cells, allocator)
	delete(sb.lifetime, allocator)
	delete(sb.moved, allocator)
	sb^ = {}
}

sandbox_seed_state :: proc(seed: u64) -> u64 {
	// The generator below stops at zero, so zero needs a substitute.
	return seed == 0 ? 0x9E3779B97F4A7C15 : seed
}

sandbox_in_bounds :: #force_inline proc(sb: ^Sandbox, x, y: i32) -> bool {
	return x >= 0 && y >= 0 && x < sb.width && y < sb.height
}

sandbox_index :: #force_inline proc(sb: ^Sandbox, x, y: i32) -> int {
	return int(y) * int(sb.width) + int(x)
}

sandbox_cell :: proc(sb: ^Sandbox, x, y: i32) -> Cell {
	if !sandbox_in_bounds(sb, x, y) do return MATERIAL_AIR
	return sb.cells[sandbox_index(sb, x, y)]
}

/*
Fill the sandbox from the authored world.

This is the join between the two halves of the game. The rectangle
comes from the generator at one cell per cell, so what the player
would walk into is what the physics starts from.
*/
sandbox_fill_from_world :: proc(sb: ^Sandbox, world: World, origin_x, origin_y: i32) {
	view := World_View {
		x    = origin_x,
		y    = origin_y,
		w    = sb.width,
		h    = sb.height,
		step = 1,
	}
	generate(world, view, sb.cells)

	sb.origin_x = origin_x
	sb.origin_y = origin_y

	// Every cell is new, so the physics state starts again with it.
	for c, i in sb.cells {
		sb.lifetime[i] = material_start_life(world.materials, c)
	}
	mem.zero_slice(sb.moved)
}

/*
The random source of the sandbox.

This is a xorshift64 generator. It belongs to the sandbox, not to the
process, so two sandboxes with the same seed stay in step.
*/
sandbox_rand :: proc(sb: ^Sandbox) -> u64 {
	x := sb.rng
	x ~= x << 13
	x ~= x >> 7
	x ~= x << 17
	sb.rng = x
	return x
}

/*
A hash of the whole sandbox state.

Old network code sent this number with each frame. When two peers
reported different numbers for the same tick, the peers had drifted
apart. The tests use it the same way.
*/
sandbox_checksum :: proc(sb: ^Sandbox) -> u64 {
	FNV_OFFSET :: 0xcbf29ce484222325
	FNV_PRIME  :: 0x100000001b3

	hash: u64 = FNV_OFFSET
	for b in sb.cells {
		hash ~= u64(b)
		hash *= FNV_PRIME
	}
	for b in slice.to_bytes(sb.lifetime) {
		hash ~= u64(b)
		hash *= FNV_PRIME
	}

	// The generator state is part of the future, so it is part of the hash.
	tail := [6]u64 {
		sb.rng,
		sb.tick,
		u64(sb.width),
		u64(sb.height),
		u64(u32(sb.origin_x)),
		u64(u32(sb.origin_y)),
	}
	for v in tail {
		hash ~= v
		hash *= FNV_PRIME
	}
	return hash
}

// The ticks a fresh cell of this material lives, or -1 for ever.
material_start_life :: proc(table: Material_Table, material: Cell) -> i16 {
	if int(material) >= len(table.materials) do return -1
	life := table.materials[material].lifetime
	if life <= 0 do return -1
	return life > 32767 ? 32767 : i16(life)
}

sandbox_put :: #force_inline proc(sb: ^Sandbox, table: Material_Table, index: int, material: Cell) {
	sb.cells[index] = material
	sb.lifetime[index] = material_start_life(table, material)
}

/*
Fill a disc with one material.

A radius of zero writes one cell. The result is the number of cells
that changed.
*/
sandbox_paint :: proc(sb: ^Sandbox, table: Material_Table, cx, cy: i32, radius: i32, material: Cell) -> (changed: int) {
	if int(material) >= len(table.materials) do return 0

	r := radius < 0 ? 0 : radius
	r2 := r * r
	life := material_start_life(table, material)

	// The loop covers only the part of the disc that lies in the
	// sandbox. A large radius near an edge then costs nothing extra.
	for y := max(cy-r, 0); y <= min(cy+r, sb.height-1); y += 1 {
		for x := max(cx-r, 0); x <= min(cx+r, sb.width-1); x += 1 {
			dx := x - cx
			dy := y - cy
			if dx*dx + dy*dy > r2 do continue

			i := sandbox_index(sb, x, y)
			if sb.cells[i] == material && sb.lifetime[i] == life do continue
			sb.cells[i] = material
			sb.lifetime[i] = life
			changed += 1
		}
	}
	return changed
}

/*
Set light material in a disc alight.

Air does not catch fire, so an ignite over empty space does nothing.
Place Fire directly to make a flame in the air.
*/
sandbox_ignite :: proc(sb: ^Sandbox, table: Material_Table, cx, cy: i32, radius: i32) -> (changed: int) {
	r := radius < 0 ? 0 : radius
	r2 := r * r

	for y := max(cy-r, 0); y <= min(cy+r, sb.height-1); y += 1 {
		for x := max(cx-r, 0); x <= min(cx+r, sb.width-1); x += 1 {
			dx := x - cx
			dy := y - cy
			if dx*dx + dy*dy > r2 do continue

			i := sandbox_index(sb, x, y)
			material := sb.cells[i]
			if material == MATERIAL_AIR do continue
			if table.materials[material].flammability == 0 do continue

			sandbox_put(sb, table, i, Cell(table.burns_to[material]))
			changed += 1
		}
	}
	return changed
}

/*
Run one tick of the simulation.

The scan runs from the bottom row up. A cell that moves is marked, so
a cell moves at most once per tick. The scan direction along a row
flips with the tick number, which stops material drifting to one side.
*/
sandbox_step :: proc(sb: ^Sandbox, table: Material_Table) {
	mem.zero_slice(sb.moved)

	left_first := (sb.tick & 1) == 0

	for y := sb.height - 1; y >= 0; y -= 1 {
		for i in 0 ..< sb.width {
			x := left_first ? i : sb.width - 1 - i
			sandbox_step_cell(sb, table, x, y)
		}
	}

	sb.tick += 1
}

sandbox_step_cell :: proc(sb: ^Sandbox, table: Material_Table, x, y: i32) {
	index := sandbox_index(sb, x, y)
	if sb.moved[index] do return

	material := sb.cells[index]
	if material == MATERIAL_AIR do return

	m := table.materials[material]

	// The lifetime runs out and the material turns into something else.
	if sb.lifetime[index] > 0 {
		sb.lifetime[index] -= 1
		if sb.lifetime[index] == 0 {
			sandbox_put(sb, table, index, Cell(table.decays_to[material]))
			sb.moved[index] = true
			return
		}
	}

	// Anything that burns on contact can set a neighbour alight.
	fuel_nearby := false
	if .Burns in m.contact {
		fuel_nearby = sandbox_spread_fire(sb, table, x, y)
	}

	// A flame holds still while fuel sits beside it. Without this rule
	// a flame climbs away in one tick and the fire never runs along a
	// trail of oil.
	if m.state == .Special && fuel_nearby do return

	switch m.state {
	case .Solid:
		// A solid stays where it is.
	case .Powder:
		sandbox_move_powder(sb, table, x, y, m)
	case .Liquid:
		sandbox_move_liquid(sb, table, x, y, m)
	case .Gas, .Special:
		sandbox_move_rising(sb, table, x, y, m)
	}
}

/*
Move a cell to a free or lighter place.

Both cells are marked, so neither moves again in this tick. This keeps
the tick simple: every cell gets at most one move.
*/
sandbox_try_move :: proc(sb: ^Sandbox, table: Material_Table, sx, sy, dx, dy: i32, rule: Move_Rule) -> bool {
	if !sandbox_in_bounds(sb, dx, dy) do return false

	to := sandbox_index(sb, dx, dy)
	if sb.moved[to] do return false

	from := sandbox_index(sb, sx, sy)
	src := sb.cells[from]
	dst := sb.cells[to]

	if dst != MATERIAL_AIR {
		dm := table.materials[dst]
		if dm.state == .Solid do return false

		sm := table.materials[src]
		switch rule {
		case .Into_Air:
			return false
		case .Sink:
			if sm.density <= dm.density do return false
		case .Rise:
			if sm.density >= dm.density do return false
		}
	}

	sb.cells[from], sb.cells[to] = sb.cells[to], sb.cells[from]
	sb.lifetime[from], sb.lifetime[to] = sb.lifetime[to], sb.lifetime[from]
	sb.moved[from] = true
	sb.moved[to] = true
	return true
}

// A powder falls straight down, then to one side and down.
sandbox_move_powder :: proc(sb: ^Sandbox, table: Material_Table, x, y: i32, m: Material) {
	cx, cy := x, y
	for _ in 0 ..< int(m.fall_speed) {
		if sandbox_try_move(sb, table, cx, cy, cx, cy+1, .Sink) {
			cy += 1
			continue
		}
		side := sandbox_rand(sb) & 1 == 0 ? i32(-1) : i32(1)
		if sandbox_try_move(sb, table, cx, cy, cx+side, cy+1, .Sink) {
			cx += side
			cy += 1
			continue
		}
		if sandbox_try_move(sb, table, cx, cy, cx-side, cy+1, .Sink) {
			cx -= side
			cy += 1
			continue
		}
		break
	}
}

// A liquid falls like a powder. When it cannot fall it spreads out.
sandbox_move_liquid :: proc(sb: ^Sandbox, table: Material_Table, x, y: i32, m: Material) {
	cx, cy := x, y
	steps := int(m.fall_speed)

	fell := false
	for _ in 0 ..< steps {
		if sandbox_try_move(sb, table, cx, cy, cx, cy+1, .Sink) {
			cy += 1
			fell = true
			continue
		}
		side := sandbox_rand(sb) & 1 == 0 ? i32(-1) : i32(1)
		if sandbox_try_move(sb, table, cx, cy, cx+side, cy+1, .Sink) {
			cx += side
			cy += 1
			fell = true
			continue
		}
		if sandbox_try_move(sb, table, cx, cy, cx-side, cy+1, .Sink) {
			cx -= side
			cy += 1
			fell = true
			continue
		}
		break
	}
	if fell do return

	// A liquid spreads sideways only while the move helps it settle.
	// Without that test a flat layer swaps left and right for ever. The
	// layer then never packs, it holds gaps that never close, and a
	// pool behaves more like a gas than a liquid.
	//
	// The move repeats up to fall_speed times, which lets a pool find
	// its level in a few ticks instead of a few hundred.
	side := sandbox_rand(sb) & 1 == 0 ? i32(-1) : i32(1)
	for _ in 0 ..< steps {
		if sandbox_liquid_can_spread(sb, table, cx, cy, side) {
			if sandbox_try_move(sb, table, cx, cy, cx+side, cy, .Into_Air) {
				cx += side
				continue
			}
		}
		if sandbox_liquid_can_spread(sb, table, cx, cy, -side) {
			if sandbox_try_move(sb, table, cx, cy, cx-side, cy, .Into_Air) {
				cx -= side
				side = -side
				continue
			}
		}
		break
	}
}

/*
Report whether a sideways move gains anything.

A liquid flows for two reasons: the ground falls away on that side, or
more liquid presses from above. A cell that has neither reason stays
where it is.
*/
sandbox_liquid_can_spread :: proc(sb: ^Sandbox, table: Material_Table, x, y, side: i32) -> bool {
	// The ground falls away, so the liquid runs downhill.
	if sandbox_in_bounds(sb, x+side, y+1) {
		if sb.cells[sandbox_index(sb, x+side, y+1)] == MATERIAL_AIR do return true
	}

	// More liquid rests on top, so this cell is under pressure.
	above := sandbox_cell(sb, x, y-1)
	if above == MATERIAL_AIR do return false
	return table.materials[above].state == .Liquid
}

// A gas and a flame climb. Now and then they drift to one side.
sandbox_move_rising :: proc(sb: ^Sandbox, table: Material_Table, x, y: i32, m: Material) {
	cx, cy := x, y
	for _ in 0 ..< int(m.fall_speed) {
		if sandbox_try_move(sb, table, cx, cy, cx, cy-1, .Rise) {
			cy -= 1
			continue
		}
		side := sandbox_rand(sb) & 1 == 0 ? i32(-1) : i32(1)
		if sandbox_try_move(sb, table, cx, cy, cx+side, cy-1, .Rise) {
			cx += side
			cy -= 1
			continue
		}
		if sandbox_try_move(sb, table, cx, cy, cx-side, cy-1, .Rise) {
			cx -= side
			cy -= 1
			continue
		}
		if sandbox_try_move(sb, table, cx, cy, cx+side, cy, .Into_Air) {
			cx += side
			continue
		}
		break
	}
}

/*
Set the neighbours of a hot cell alight.

The chance comes from the flammability of the neighbour. The new
material comes from the burns_to table, so the data file controls the
reaction.

The result reports whether fuel sits next to the cell.
*/
sandbox_spread_fire :: proc(sb: ^Sandbox, table: Material_Table, x, y: i32) -> (fuel_nearby: bool) {
	// A flame reaches the corners too. A pool that has spread thin
	// holds gaps, and a fire that only reaches the four sides stops at
	// the first gap.
	offsets := [8][2]i32 {
		{1, 0}, {-1, 0}, {0, 1}, {0, -1},
		{1, 1}, {1, -1}, {-1, 1}, {-1, -1},
	}

	for o in offsets {
		nx := x + o[0]
		ny := y + o[1]
		if !sandbox_in_bounds(sb, nx, ny) do continue

		i := sandbox_index(sb, nx, ny)
		material := sb.cells[i]
		if material == MATERIAL_AIR do continue

		flammability := table.materials[material].flammability
		if flammability == 0 do continue
		fuel_nearby = true

		// Flammability 8 gives a one in four chance each tick.
		if sandbox_rand(sb) % 256 >= u64(flammability) * 8 do continue

		sandbox_put(sb, table, i, Cell(table.burns_to[material]))
		sb.moved[i] = true
	}
	return fuel_nearby
}

// Count the cells of each material. The result is indexed like the table.
sandbox_census :: proc(sb: ^Sandbox, counts: []int) {
	slice.zero(counts)
	for c in sb.cells {
		if int(c) < len(counts) do counts[c] += 1
	}
}

// ------------------------------------------------------------
// Tests (run with: odin test src  from repo root)
// ------------------------------------------------------------

@(private = "file")
test_sandbox :: proc(t: ^testing.T, width, height: i32, seed: u64) -> (Sandbox, Material_Table) {
	table, load_ok := load_materials("data/materials.txt")
	testing.expect(t, load_ok, "materials must load")

	sb, make_ok := sandbox_make(width, height, seed)
	testing.expect(t, make_ok, "the sandbox must be created")
	return sb, table
}

@(test)
test_sandbox_starts_empty :: proc(t: ^testing.T) {
	sb, table := test_sandbox(t, 16, 16, 1)
	defer sandbox_destroy(&sb)
	defer destroy_material_table(table)

	for c in sb.cells {
		testing.expect(t, c == MATERIAL_AIR, "a new sandbox must hold only air")
	}
	testing.expect(t, sb.tick == 0)
}

@(test)
test_powder_falls_to_the_floor :: proc(t: ^testing.T) {
	sb, table := test_sandbox(t, 8, 16, 7)
	defer sandbox_destroy(&sb)
	defer destroy_material_table(table)

	sand, _ := find_material_index(table, "Sand")
	sandbox_paint(&sb, table, 4, 0, 0, Cell(sand))

	for _ in 0 ..< 32 do sandbox_step(&sb, table)

	testing.expect(t, int(sandbox_cell(&sb, 4, sb.height-1)) == sand, "sand must rest on the floor")
	testing.expect(t, sandbox_cell(&sb, 4, 0) == MATERIAL_AIR, "the start cell must be empty")
}

@(test)
test_solid_never_moves :: proc(t: ^testing.T) {
	sb, table := test_sandbox(t, 8, 8, 3)
	defer sandbox_destroy(&sb)
	defer destroy_material_table(table)

	rock, _ := find_material_index(table, "Rock")
	sandbox_paint(&sb, table, 4, 2, 0, Cell(rock))

	for _ in 0 ..< 20 do sandbox_step(&sb, table)

	testing.expect(t, int(sandbox_cell(&sb, 4, 2)) == rock, "rock must stay in place")
}

@(test)
test_gas_rises_through_liquid :: proc(t: ^testing.T) {
	// Smoke is heavier than air but lighter than water, so it must
	// climb out of a pool instead of sitting under it.
	sb, table := test_sandbox(t, 8, 16, 11)
	defer sandbox_destroy(&sb)
	defer destroy_material_table(table)

	water, _ := find_material_index(table, "Water")
	smoke, _ := find_material_index(table, "Smoke")

	for y in i32(8) ..< 16 {
		for x in i32(0) ..< 8 do sandbox_paint(&sb, table, x, y, 0, Cell(water))
	}
	sandbox_paint(&sb, table, 4, 15, 0, Cell(smoke))

	start := sb.height
	for _ in 0 ..< 40 do sandbox_step(&sb, table)

	found := i32(-1)
	for y in i32(0) ..< sb.height {
		for x in i32(0) ..< sb.width {
			if int(sandbox_cell(&sb, x, y)) == smoke {
				found = y
				break
			}
		}
		if found >= 0 do break
	}
	testing.expect(t, found >= 0, "the smoke must still exist")
	testing.expect(t, found < start-1, "the smoke must climb")
}

@(test)
test_denser_powder_sinks_through_liquid :: proc(t: ^testing.T) {
	sb, table := test_sandbox(t, 8, 16, 5)
	defer sandbox_destroy(&sb)
	defer destroy_material_table(table)

	water, _ := find_material_index(table, "Water")
	sand, _ := find_material_index(table, "Sand")

	for y in i32(4) ..< 16 {
		for x in i32(0) ..< 8 do sandbox_paint(&sb, table, x, y, 0, Cell(water))
	}
	sandbox_paint(&sb, table, 4, 0, 0, Cell(sand))

	for _ in 0 ..< 60 do sandbox_step(&sb, table)

	deepest := i32(-1)
	for y in i32(0) ..< sb.height {
		for x in i32(0) ..< sb.width {
			if int(sandbox_cell(&sb, x, y)) == sand do deepest = y
		}
	}
	testing.expect(t, deepest == sb.height-1, "sand must sink to the floor")
}

@(test)
test_a_flat_liquid_layer_stays_still :: proc(t: ^testing.T) {
	// A liquid that rests on a flat floor with nothing above has no
	// reason to move. An earlier rule let it swap left and right for
	// ever, which left gaps that never closed.
	sb, table := test_sandbox(t, 16, 8, 21)
	defer sandbox_destroy(&sb)
	defer destroy_material_table(table)

	water, _ := find_material_index(table, "Water")
	for x in i32(0) ..< 16 do sandbox_paint(&sb, table, x, 7, 0, Cell(water))

	for _ in 0 ..< 20 do sandbox_step(&sb, table)

	for x in i32(0) ..< 16 {
		testing.expect(t, int(sandbox_cell(&sb, x, 7)) == water, "the layer must stay whole")
	}
	for y in i32(0) ..< 7 {
		for x in i32(0) ..< 16 {
			testing.expect(t, sandbox_cell(&sb, x, y) == MATERIAL_AIR, "nothing must climb out")
		}
	}
}

@(test)
test_a_liquid_still_spreads_out :: proc(t: ^testing.T) {
	// The rule above must not stop a pool from finding its level.
	sb, table := test_sandbox(t, 32, 16, 22)
	defer sandbox_destroy(&sb)
	defer destroy_material_table(table)

	water, _ := find_material_index(table, "Water")
	for y in i32(8) ..< 16 do sandbox_paint(&sb, table, 16, y, 0, Cell(water))

	for _ in 0 ..< 60 do sandbox_step(&sb, table)

	width := 0
	for x in i32(0) ..< 32 {
		for y in i32(0) ..< 16 {
			if int(sandbox_cell(&sb, x, y)) == water {
				width += 1
				break
			}
		}
	}
	testing.expect(t, width > 4, "a column of water must spread along the floor")
}

@(test)
test_lifetime_turns_fire_into_smoke :: proc(t: ^testing.T) {
	sb, table := test_sandbox(t, 8, 8, 2)
	defer sandbox_destroy(&sb)
	defer destroy_material_table(table)

	fire, _ := find_material_index(table, "Fire")
	smoke, _ := find_material_index(table, "Smoke")

	sandbox_paint(&sb, table, 4, 7, 0, Cell(fire))

	counts := make([]int, len(table.materials))
	defer delete(counts)

	// Fire lives for 90 ticks. After that only smoke can remain.
	for _ in 0 ..< 95 do sandbox_step(&sb, table)
	sandbox_census(&sb, counts)

	testing.expect(t, counts[fire] == 0, "the fire must burn out")
	testing.expect(t, counts[smoke] == 1, "the fire must leave smoke")
}

@(test)
test_fire_spreads_through_oil :: proc(t: ^testing.T) {
	sb, table := test_sandbox(t, 32, 8, 13)
	defer sandbox_destroy(&sb)
	defer destroy_material_table(table)

	oil, _ := find_material_index(table, "Oil")
	rock, _ := find_material_index(table, "Rock")

	// A tray of rock holds a pool of oil in place.
	for x in i32(0) ..< 32 {
		sandbox_paint(&sb, table, x, 7, 0, Cell(rock))
		sandbox_paint(&sb, table, x, 6, 0, Cell(oil))
	}
	fire, _ := find_material_index(table, "Fire")
	sandbox_paint(&sb, table, 0, 6, 0, Cell(fire))

	counts := make([]int, len(table.materials))
	defer delete(counts)

	burned := false
	for _ in 0 ..< 300 {
		sandbox_step(&sb, table)
		sandbox_census(&sb, counts)
		if counts[oil] == 0 {
			burned = true
			break
		}
	}
	testing.expect(t, burned, "the fire must run along the oil")
}

@(test)
test_ignite_needs_fuel :: proc(t: ^testing.T) {
	sb, table := test_sandbox(t, 8, 8, 17)
	defer sandbox_destroy(&sb)
	defer destroy_material_table(table)

	oil, _ := find_material_index(table, "Oil")

	testing.expect(t, sandbox_ignite(&sb, table, 4, 4, 2) == 0, "air must not ignite")

	sandbox_paint(&sb, table, 4, 4, 0, Cell(oil))
	testing.expect(t, sandbox_ignite(&sb, table, 4, 4, 1) == 1, "oil must ignite")
}

@(test)
test_same_seed_gives_the_same_checksum :: proc(t: ^testing.T) {
	table, load_ok := load_materials("data/materials.txt")
	defer destroy_material_table(table)
	testing.expect(t, load_ok)

	sand, _ := find_material_index(table, "Sand")
	water, _ := find_material_index(table, "Water")

	run :: proc(table: Material_Table, seed: u64, sand, water: Cell) -> u64 {
		sb, _ := sandbox_make(48, 32, seed)
		defer sandbox_destroy(&sb)

		for step in 0 ..< 120 {
			if step % 10 == 0 {
				sandbox_paint(&sb, table, 24, 0, 3, sand)
				sandbox_paint(&sb, table, 10, 0, 2, water)
			}
			sandbox_step(&sb, table)
		}
		return sandbox_checksum(&sb)
	}

	a := run(table, 12345, Cell(sand), Cell(water))
	b := run(table, 12345, Cell(sand), Cell(water))
	c := run(table, 54321, Cell(sand), Cell(water))

	testing.expect(t, a == b, "the same seed must give the same world")
	testing.expect(t, a != c, "a different seed must give a different world")
}
