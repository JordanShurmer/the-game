package game

import "core:math"
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

// See docs/physics.md, "Explosions". A small blast still casts enough
// rays to leave no gaps in its crater; a big one gets more rays so the
// gaps do not open up again as the radius grows.
EXPLODE_MIN_RAYS      :: 24
EXPLODE_RAYS_PER_CELL :: 6

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
Turn one burning cell into fire, or set off a blast.

sandbox_ignite and sandbox_spread_fire both reach a cell that is about
to catch light. This is the one place that decides what "catching
light" means for that cell, so the two callers cannot drift apart: a
material with `explosive` above zero detonates, and everything else
just burns. See docs/physics.md, "Explosions".
*/
sandbox_ignite_cell :: proc(sb: ^Sandbox, table: Material_Table, x, y: i32) {
	index := sandbox_index(sb, x, y)
	material := sb.cells[index]
	m := table.materials[material]

	if m.explosive > 0 {
		// The grain itself clears to air before the blast starts. If
		// it stayed as gunpowder, the first ray of its own blast
		// would have to special-case the centre cell.
		sandbox_put(sb, table, index, MATERIAL_AIR)
		sb.moved[index] = true
		sandbox_explode(sb, table, x, y, i32(m.explosive) / 4, m.explosive)
		return
	}

	sandbox_put(sb, table, index, Cell(table.burns_to[material]))
	sb.moved[index] = true
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

			sandbox_ignite_cell(sb, table, x, y)
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

	// A cell that meets its reaction partner turns into the pair the
	// table names. Only one of the four sides is tested, and only one
	// reaction happens, per cell per tick: testing all four would cost
	// four times as much and only make an already-certain reaction
	// happen a little sooner, and letting a cell both react and fall
	// in the same tick would need a second flag to stop it doubling
	// up. `reacts` gates this so Air, which is in no row, pays one
	// array read and nothing more. See docs/physics.md, "The reaction
	// table".
	if table.reacts[material] {
		offsets := [4][2]i32{{1, 0}, {-1, 0}, {0, 1}, {0, -1}}
		o := offsets[sandbox_rand(sb) & 3]
		nx := x + o[0]
		ny := y + o[1]

		if sandbox_in_bounds(sb, nx, ny) {
			ni := sandbox_index(sb, nx, ny)
			// A neighbour that already changed this tick is not a
			// safe partner: reacting with it now would overwrite
			// whatever just wrote it there.
			if !sb.moved[ni] {
				neighbour := sb.cells[ni]
				n := len(table.materials)
				row := table.reaction_at[int(material)*n+int(neighbour)]
				if row >= 0 {
					r := table.reactions[row]
					if sandbox_rand(sb) % 256 < u64(r.chance) {
						sandbox_put(sb, table, index, Cell(r.c))
						sandbox_put(sb, table, ni, Cell(r.d))
						sb.moved[index] = true
						sb.moved[ni] = true
						return
					}
				}
			}
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

		sandbox_ignite_cell(sb, table, nx, ny)
	}
	return fuel_nearby
}

/*
Cast rays from a point. Hard material stops them.

The model is Noita's: a blast is rays, not a disc, so a wall casts a
shadow and a corridor channels the blast. The angles are fixed, not
drawn from sandbox_rand: a replay must give the same crater, and a
disc would clear straight through a wall the rays would have to stop
at. See docs/physics.md, "Explosions".
*/
sandbox_explode :: proc(sb: ^Sandbox, table: Material_Table, cx, cy: i32, radius: i32, power: u8) -> (broken: int) {
	r := radius < 0 ? 0 : radius
	if r == 0 || power == 0 do return 0

	rays := max(EXPLODE_MIN_RAYS, r*EXPLODE_RAYS_PER_CELL)
	inner_r := r / 3

	// The table resolved Fire by name once, at load. A blast leaves
	// fire in its inner third, and a chain of gunpowder is many blasts
	// in one tick, so searching the table by name here would be the
	// most expensive thing in the step.
	fire_cell := Cell(table.fire)

	for ray in 0 ..< rays {
		angle := f32(ray) / f32(rays) * 2 * math.PI
		dx := math.cos(angle)
		dy := math.sin(angle)

		// The energy is an i32. Bedrock costs 256 to cross, and a u8
		// cannot hold that, so a ray with full power would wrap round
		// to a small number and cross bedrock as if it were air.
		energy := i32(power)

		for step in i32(1) ..= r {
			x := cx + i32(math.round(dx * f32(step)))
			y := cy + i32(math.round(dy * f32(step)))
			if !sandbox_in_bounds(sb, x, y) do break

			i := sandbox_index(sb, x, y)
			material := sb.cells[i]
			cost := i32(table.materials[material].hardness) + 1
			if energy < cost do break
			energy -= cost

			// Already open, either from the start or from an earlier
			// ray that crossed this cell first. The ray still paid to
			// cross it above; there is nothing left to clear.
			if material == MATERIAL_AIR || material == fire_cell do continue

			broken += 1
			target := step <= inner_r ? fire_cell : MATERIAL_AIR
			sandbox_put(sb, table, i, target)
			// Every cell the blast writes is marked moved, so the
			// same tick's scan does not reach it again. Without this
			// a cleared cell that lands ahead of the scan position
			// could spread fire and set off a second blast before
			// this tick is over.
			sb.moved[i] = true

			sandbox_crumble_neighbours(sb, table, x, y)
		}
	}
	return broken
}

/*
Crumble the four neighbours of a cell the blast just cleared.

crumbles_to defaults to the material itself, so this is a no-op for
anything that does not crumble; only the few materials with a real row
in the cold table change here. See docs/physics.md, "The materials".
*/
sandbox_crumble_neighbours :: proc(sb: ^Sandbox, table: Material_Table, x, y: i32) {
	offsets := [4][2]i32{{1, 0}, {-1, 0}, {0, 1}, {0, -1}}
	for o in offsets {
		nx := x + o[0]
		ny := y + o[1]
		if !sandbox_in_bounds(sb, nx, ny) do continue

		ni := sandbox_index(sb, nx, ny)
		neighbour := sb.cells[ni]
		crumbled := Cell(table.crumbles_to[neighbour])
		if crumbled == neighbour do continue

		sandbox_put(sb, table, ni, crumbled)
		sb.moved[ni] = true
	}
}

/*
Remove every cell in a disc that is soft enough.

This is sandbox_paint's disc loop with a hardness test instead of an
unconditional write; a cell that is too hard is left as it is. See
docs/physics.md, "Digging and breaking".
*/
sandbox_dig :: proc(sb: ^Sandbox, table: Material_Table, cx, cy: i32, radius: i32, power: u8) -> (removed: int) {
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
			if table.materials[material].hardness > power do continue

			sandbox_put(sb, table, i, MATERIAL_AIR)
			removed += 1
		}
	}
	return removed
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

// ------------------------------------------------------------
// Reactions, explosions, and digging (docs/physics.md, step 2)
// ------------------------------------------------------------

@(test)
test_water_quenches_fire_into_steam :: proc(t: ^testing.T) {
	// Without the reaction table, fire only ever dies from its own
	// lifetime. Water sitting right beside a young flame would have
	// no effect on it at all, and the flame would still be there long
	// after the water fell past.
	sb, table := test_sandbox(t, 8, 8, 9)
	defer sandbox_destroy(&sb)
	defer destroy_material_table(table)

	fire, _ := find_material_index(table, "Fire")
	steam, _ := find_material_index(table, "Steam")
	rock, _ := find_material_index(table, "Rock")
	water, _ := find_material_index(table, "Water")

	for x in i32(0) ..< 8 do sandbox_paint(&sb, table, x, 7, 0, Cell(rock))
	sandbox_paint(&sb, table, 4, 6, 0, Cell(fire))
	sandbox_paint(&sb, table, 4, 5, 0, Cell(water))

	counts := make([]int, len(table.materials))
	defer delete(counts)

	found := false
	for _ in 0 ..< 300 {
		sandbox_step(&sb, table)
		sandbox_census(&sb, counts)
		if counts[fire] == 0 && counts[steam] > 0 {
			found = true
			break
		}
	}
	testing.expect(t, found, "water must quench the fire and leave steam behind")
}

@(test)
test_water_on_lava_leaves_obsidian :: proc(t: ^testing.T) {
	// This is the reaction table's whole reason to exist: Noita's
	// water-meets-lava moment. Without a [Reactions] row for the
	// pair, water would just float on lava for ever and no obsidian
	// would ever appear.
	sb, table := test_sandbox(t, 8, 16, 4)
	defer sandbox_destroy(&sb)
	defer destroy_material_table(table)

	lava, _ := find_material_index(table, "Lava")
	water, _ := find_material_index(table, "Water")
	obsidian, _ := find_material_index(table, "Obsidian")

	for x in i32(0) ..< 8 do sandbox_paint(&sb, table, x, 7, 0, Cell(lava))
	for x in i32(0) ..< 8 do sandbox_paint(&sb, table, x, 6, 0, Cell(water))

	counts := make([]int, len(table.materials))
	defer delete(counts)

	found := false
	for _ in 0 ..< 2000 {
		sandbox_step(&sb, table)
		sandbox_census(&sb, counts)
		if counts[obsidian] > 0 {
			found = true
			break
		}
	}
	testing.expect(t, found, "water meeting lava must leave obsidian")
}

@(test)
test_acid_eats_rock_and_runs_out :: proc(t: ^testing.T) {
	// Acid + Rock -> Air + Air uses up the acid along with the rock it
	// dissolves. Without that, an acid pool would either do nothing
	// to solid rock, or eat straight through the floor of the world
	// with nothing to stop it.
	sb, table := test_sandbox(t, 6, 30, 6)
	defer sandbox_destroy(&sb)
	defer destroy_material_table(table)

	acid, _ := find_material_index(table, "Acid")
	rock, _ := find_material_index(table, "Rock")

	for y in i32(0) ..< 3 {
		for x in i32(0) ..< 6 do sandbox_paint(&sb, table, x, y, 0, Cell(acid))
	}
	for y in i32(3) ..< 30 {
		for x in i32(0) ..< 6 do sandbox_paint(&sb, table, x, y, 0, Cell(rock))
	}
	rock_start := 6 * 27

	counts := make([]int, len(table.materials))
	defer delete(counts)

	for _ in 0 ..< 6000 do sandbox_step(&sb, table)
	sandbox_census(&sb, counts)

	testing.expect(t, counts[acid] == 0, "a small pool of acid must be used up")
	testing.expectf(
		t, counts[rock] > rock_start-6*3-1,
		"the pool must stop after eating roughly its own size of rock, not bore for ever: %d of %d left",
		counts[rock], rock_start,
	)
}

@(test)
test_wooden_beam_burns_to_ash_on_the_floor :: proc(t: ^testing.T) {
	// This exercises burns_to, lifetime and decays_to end to end, with
	// no new code in the step: light one end, the fire runs along the
	// beam on contact, and 300 ticks later each cell is ash. Without
	// the chain working, the beam would either not catch at all or
	// stay wood for ever.
	sb, table := test_sandbox(t, 24, 8, 15)
	defer sandbox_destroy(&sb)
	defer destroy_material_table(table)

	wood, _ := find_material_index(table, "Wood")
	burning_wood, _ := find_material_index(table, "Burning_Wood")
	ash, _ := find_material_index(table, "Ash")
	rock, _ := find_material_index(table, "Rock")

	for x in i32(0) ..< 24 do sandbox_paint(&sb, table, x, 7, 0, Cell(rock))
	for x in i32(0) ..< 24 do sandbox_paint(&sb, table, x, 6, 0, Cell(wood))

	sandbox_ignite(&sb, table, 0, 6, 0)

	counts := make([]int, len(table.materials))
	defer delete(counts)

	burned_out := false
	for _ in 0 ..< 3000 {
		sandbox_step(&sb, table)
		sandbox_census(&sb, counts)
		if counts[wood] == 0 && counts[burning_wood] == 0 {
			burned_out = true
			break
		}
	}
	testing.expect(t, burned_out, "the whole beam must finish burning")
	testing.expect(t, counts[ash] == 24, "every cell of the beam must become ash")
	for x in i32(0) ..< 24 {
		testing.expectf(t, int(sandbox_cell(&sb, x, 6)) == ash, "cell %d must rest as ash on the floor", x)
	}
}

@(test)
test_explosion_casts_a_shadow_behind_bedrock :: proc(t: ^testing.T) {
	// The point of rays over a disc: a wall stops what is behind it.
	// A bedrock pillar sits between the blast and a patch of rock
	// beyond it. Every straight line from the blast to that patch has
	// to cross the pillar, so if the patch survives whole, the rule
	// really is rays that a wall can block and not a circle drawn
	// around the centre.
	sb, table := test_sandbox(t, 41, 41, 3)
	defer sandbox_destroy(&sb)
	defer destroy_material_table(table)

	rock, _ := find_material_index(table, "Rock")
	bedrock, _ := find_material_index(table, "Bedrock")

	for y in i32(0) ..< 41 {
		for x in i32(0) ..< 41 do sandbox_paint(&sb, table, x, y, 0, Cell(rock))
	}
	// A wide, thick pillar directly above the blast centre.
	for y in i32(15) ..< 20 {
		for x in i32(16) ..< 25 do sandbox_paint(&sb, table, x, y, 0, Cell(bedrock))
	}

	broken := sandbox_explode(&sb, table, 20, 30, 25, 255)
	testing.expect(t, broken > 0, "the blast must clear something")

	shadow_whole := true
	for y in i32(0) ..< 13 {
		for x in i32(18) ..< 23 {
			if int(sandbox_cell(&sb, x, y)) != rock do shadow_whole = false
		}
	}
	testing.expect(t, shadow_whole, "the shadow of the pillar must stay whole rock")

	side_cleared := false
	for y in i32(5) ..< 15 {
		for x in i32(0) ..< 15 {
			if sandbox_cell(&sb, x, y) == MATERIAL_AIR do side_cleared = true
		}
	}
	testing.expect(t, side_cleared, "the blast must clear rock beside the pillar, where nothing blocks the rays")
}

@(test)
test_blasted_rock_leaves_gravel_that_falls :: proc(t: ^testing.T) {
	sb, table := test_sandbox(t, 20, 20, 8)
	defer sandbox_destroy(&sb)
	defer destroy_material_table(table)

	rock, _ := find_material_index(table, "Rock")
	gravel, _ := find_material_index(table, "Gravel")

	for y in i32(0) ..< 20 {
		for x in i32(0) ..< 20 do sandbox_paint(&sb, table, x, y, 0, Cell(rock))
	}

	broken := sandbox_explode(&sb, table, 10, 5, 6, 80)
	testing.expect(t, broken > 0, "the blast must clear rock")

	counts := make([]int, len(table.materials))
	defer delete(counts)
	sandbox_census(&sb, counts)
	testing.expect(t, counts[gravel] > 0, "the rock crumbling at the crater edge must leave gravel")

	sum_y :: proc(sb: ^Sandbox, gravel: int) -> i64 {
		total: i64 = 0
		for y in i32(0) ..< sb.height {
			for x in i32(0) ..< sb.width {
				if int(sandbox_cell(sb, x, y)) == gravel do total += i64(y)
			}
		}
		return total
	}

	before := sum_y(&sb, gravel)
	for _ in 0 ..< 80 do sandbox_step(&sb, table)
	after := sum_y(&sb, gravel)

	testing.expect(t, after > before, "gravel is a powder, so it must fall once the blast opens space under it")
}

@(test)
test_gunpowder_pile_chain_detonates_and_leaves_a_crater :: proc(t: ^testing.T) {
	// The recursion guard is the point of this test. Every cell a
	// blast writes is marked in `moved`, so a grain that goes off
	// cannot set off a neighbour that is still ahead of the scan in
	// the same tick. Without that rule a dense pile can cascade
	// through itself inside one call and overflow the stack; with it,
	// the pile still fully detonates, just spread over the ticks it
	// takes for the fire to walk from grain to grain. Running to
	// completion here is itself part of what this test checks.
	sb, table := test_sandbox(t, 40, 40, 21)
	defer sandbox_destroy(&sb)
	defer destroy_material_table(table)

	gunpowder, _ := find_material_index(table, "Gunpowder")

	for y in i32(5) ..< 35 {
		for x in i32(5) ..< 35 do sandbox_paint(&sb, table, x, y, 0, Cell(gunpowder))
	}
	start_count := 30 * 30

	sandbox_ignite(&sb, table, 20, 20, 0)

	for _ in 0 ..< 5000 do sandbox_step(&sb, table)

	counts := make([]int, len(table.materials))
	defer delete(counts)
	sandbox_census(&sb, counts)

	testing.expectf(
		t, counts[gunpowder] < start_count/2,
		"the pile must have detonated down substantially: %d of %d grains left",
		counts[gunpowder], start_count,
	)
	testing.expect(t, counts[int(MATERIAL_AIR)] > 0, "the blast must leave a crater of air")
}

@(test)
test_dig_removes_rock_but_not_steel_or_bedrock :: proc(t: ^testing.T) {
	sb, table := test_sandbox(t, 10, 4, 1)
	defer sandbox_destroy(&sb)
	defer destroy_material_table(table)

	rock, _ := find_material_index(table, "Rock")
	steel, _ := find_material_index(table, "Steel")
	bedrock, _ := find_material_index(table, "Bedrock")

	sandbox_paint(&sb, table, 2, 2, 0, Cell(rock))
	sandbox_paint(&sb, table, 5, 2, 0, Cell(steel))
	sandbox_paint(&sb, table, 8, 2, 0, Cell(bedrock))

	removed := sandbox_dig(&sb, table, 2, 2, 0, 8)
	testing.expect(t, removed == 1, "rock at exactly the wizard's power must be dug")
	testing.expect(t, sandbox_cell(&sb, 2, 2) == MATERIAL_AIR, "the rock cell must be gone")

	removed_steel := sandbox_dig(&sb, table, 5, 2, 0, 8)
	testing.expect(t, removed_steel == 0, "steel must resist the wizard's dig power")
	testing.expect(t, int(sandbox_cell(&sb, 5, 2)) == steel, "steel must still be there")

	removed_bedrock := sandbox_dig(&sb, table, 8, 2, 0, 8)
	testing.expect(t, removed_bedrock == 0, "bedrock must resist the wizard's dig power")
	testing.expect(t, int(sandbox_cell(&sb, 8, 2)) == bedrock, "bedrock must still be there")
}

@(test)
test_same_seed_gives_the_same_checksum_with_explode_and_dig :: proc(t: ^testing.T) {
	// This is the property the whole input queue depends on. Reactions
	// draw from sandbox_rand and explosions do not, but a command list
	// that mixes both must still replay bit for bit, or two clients
	// running the same session would drift apart the first time
	// either a bomb or a spell went off.
	table, load_ok := load_materials("data/materials.txt")
	defer destroy_material_table(table)
	testing.expect(t, load_ok)

	sand, _ := find_material_index(table, "Sand")
	water, _ := find_material_index(table, "Water")
	rock, _ := find_material_index(table, "Rock")
	gunpowder, _ := find_material_index(table, "Gunpowder")

	run :: proc(table: Material_Table, seed: u64, sand, water, rock, gunpowder: Cell) -> u64 {
		sb, _ := sandbox_make(48, 32, seed)
		defer sandbox_destroy(&sb)

		for y in i32(20) ..< 32 {
			for x in i32(0) ..< 48 do sandbox_paint(&sb, table, x, y, 0, rock)
		}

		for step in 0 ..< 200 {
			switch step {
			case 0:
				sandbox_paint(&sb, table, 24, 0, 3, sand)
				sandbox_paint(&sb, table, 10, 0, 2, water)
			case 40:
				sandbox_paint(&sb, table, 30, 10, 3, gunpowder)
			case 60:
				sandbox_explode(&sb, table, 30, 10, 6, 60)
			case 100:
				sandbox_dig(&sb, table, 20, 25, 4, 8)
			}
			sandbox_step(&sb, table)
		}
		return sandbox_checksum(&sb)
	}

	a := run(table, 777, Cell(sand), Cell(water), Cell(rock), Cell(gunpowder))
	b := run(table, 777, Cell(sand), Cell(water), Cell(rock), Cell(gunpowder))
	c := run(table, 999, Cell(sand), Cell(water), Cell(rock), Cell(gunpowder))

	testing.expect(t, a == b, "the same seed and the same command list must give the same checksum")
	testing.expect(t, a != c, "a different seed must still diverge")
}
