package game

import "core:math"
import testing "check"
import rl "vendor:raylib"

FIREFLY_MAX :: 24

// A firefly is a light with no body, and the light it carries is the
// Firefly_Light material. See docs/lighting.md, "Every light is a material";
// test_the_lights_of_the_world_are_ordered holds it under the trail he leaves.
FIREFLY_REACH :: 9
FIREFLY_FALL :: Light_Fall{open = 176, open_diag = 150, dense = 96, dense_diag = 64}

FIREFLY_DRIFT_X :: 13.0
FIREFLY_DRIFT_Y :: 6.0
FIREFLY_RATE_SLOW :: 0.45
FIREFLY_RATE_FAST :: 1.25
FIREFLY_PULSE_HZ :: 2.1
FIREFLY_DIM :: 0.3

FIREFLY_HALO :: 4
FIREFLY_BLAZE :: 0
FIREFLY_PEAK :: 0.5

FIREFLY_GLOW :: rl.Color{176, 255, 116, 255}
FIREFLY_CORE :: rl.Color{240, 255, 208, 255}

FIREFLY_SALT :: 0x0000_0000_0000_0021

Firefly :: struct {
	home_x, home_y:   f32,
	x, y:             f32,
	rate_x, rate_y:   f32,
	phase_x, phase_y: u8,
	pulse:            u8,
	lit:              bool,
	lx, ly:           i32,
}

#assert(size_of(Firefly) == 36)

Firefly_Swarm :: struct {
	flies: [FIREFLY_MAX]Firefly,
	count: i32,
	clock: f32,
}

// Slots either side of a point the gather looks in: a box of eleven by
// eleven, which is a whole play square and more.
FIREFLY_SEARCH :: 5

// Gather the swarm over the firefly marks nearest a point -- the
// spawn, when the world loads. A mark is a cell of Firefly_Light
// painted in an authored tile and lifted out by the loader (see
// Tile_Mark), so the tiles say where every firefly in the world lives
// and this only has to ask the lattice which tiles are nearby. Nothing
// here names a room: paint a mark in any tile of any biome and the
// swarm hangs there.
//
// Nearer marks are taken first, so when the box holds more marks than
// the swarm has flies, the far pond is the one that goes short.
firefly_gather :: proc(world: ^World, near_x, near_y: i32) -> (swarm: Firefly_Swarm) {
	firefly := world.materials.firefly
	home_sx := tile_slot(near_x)
	home_sy := tile_slot(near_y)

	dist: [FIREFLY_MAX]i64

	for sy in home_sy - FIREFLY_SEARCH ..= home_sy + FIREFLY_SEARCH {
		for sx in home_sx - FIREFLY_SEARCH ..= home_sx + FIREFLY_SEARCH {
			id := world_biome_at(world^, sx * TILE_SIZE + TILE_SIZE / 2, sy * TILE_SIZE + TILE_SIZE / 2)
			b := world.biomes.biomes[id]
			if b.generator != .Wang || b.tile_base == TILE_NONE do continue
			tile := wang_tile_at(world.seed, b, sx, sy)

			for m in world.tiles.marks {
				if m.tile != tile || m.material != firefly do continue

				wx := sx * TILE_SIZE + i32(m.x)
				wy := sy * TILE_SIZE + i32(m.y)
				dx := i64(wx - near_x)
				dy := i64(wy - near_y)
				d := dx * dx + dy * dy

				at := swarm.count
				for at > 0 && d < dist[at - 1] {
					if int(at) < FIREFLY_MAX {
						swarm.flies[at] = swarm.flies[at - 1]
						dist[at] = dist[at - 1]
					}
					at -= 1
				}
				if int(at) >= FIREFLY_MAX do continue

				h := wang_hash(world.seed, FIREFLY_SALT, wx, wy)
				swarm.flies[at] = Firefly {
					home_x  = f32(wx),
					home_y  = f32(wy),
					rate_x  = firefly_rate(h >> 8),
					rate_y  = firefly_rate(h >> 16),
					phase_x = u8(h >> 24),
					phase_y = u8(h >> 32),
					pulse   = u8(h >> 40),
				}
				dist[at] = d
				swarm.count = min(swarm.count + 1, FIREFLY_MAX)
			}
		}
	}

	firefly_place(&swarm)
	return swarm
}

@(private = "file")
firefly_rate :: proc(bits: u64) -> f32 {
	part := f32(bits & 255) / 255
	return FIREFLY_RATE_SLOW + part * (FIREFLY_RATE_FAST - FIREFLY_RATE_SLOW)
}

firefly_step :: proc(swarm: ^Firefly_Swarm) {
	if swarm.count == 0 do return
	swarm.clock += 1.0 / PLAYER_TICK_HZ
	firefly_place(swarm)
}

@(private = "file")
firefly_place :: proc(swarm: ^Firefly_Swarm) {
	turn :: #force_inline proc(phase: u8) -> f32 {
		return f32(phase) * (2 * math.PI / 256)
	}

	for i in 0 ..< int(swarm.count) {
		f := &swarm.flies[i]
		f.x = f.home_x + FIREFLY_DRIFT_X * math.sin(swarm.clock * f.rate_x + turn(f.phase_x))
		f.y = f.home_y + FIREFLY_DRIFT_Y * math.sin(swarm.clock * f.rate_y + turn(f.phase_y))
	}
}

firefly_glow :: proc(f: Firefly, clock: f64) -> f32 {
	phase := f32(clock) * FIREFLY_PULSE_HZ + f32(f.pulse) * (2 * math.PI / 256)
	beat := 0.5 + 0.5 * math.sin(phase)
	return FIREFLY_DIM + (1 - FIREFLY_DIM) * beat * beat * beat
}

firefly_power :: proc(table: Material_Table, f: Firefly, clock: f32) -> u8 {
	return u8(f32(light_lumens(table, table.firefly)) * firefly_glow(f, f64(clock)))
}

@(private = "file")
firefly_test_sim :: proc(t: ^testing.T, s: ^Sim) -> bool {
	if !testing.expect(t, sim_load(s) == .None, "the world must load") do return false
	// The pond is underground now, so a test about the light of the
	// swarm walks him down to it first: flies outside the light square
	// throw nothing, and a swarm nobody is near is dark on purpose.
	if !testing.expect(t, sim_stand_by_the_swarm(s), "the pond must have a shore to stand on") {
		sim_unload(s)
		return false
	}
	if !testing.expect(t, s.flies.count > 0, "the shipped pond must gather a swarm") {
		sim_unload(s)
		return false
	}
	sim_play_begin(s)
	return true
}

@(test)
test_the_fireflies_hang_over_the_water_and_never_leave_it :: proc(t: ^testing.T) {
	s: Sim
	if !firefly_test_sim(t, &s) do return
	defer sim_unload(&s)

	for _ in 0 ..< 900 {
		firefly_step(&s.flies)

		for i in 0 ..< int(s.flies.count) {
			f := s.flies.flies[i]
			testing.expectf(
				t,
				abs(f.x - f.home_x) <= FIREFLY_DRIFT_X,
				"a firefly must stay by the mark it was painted at, and one is %v cells from home",
				f.x - f.home_x,
			)
			testing.expectf(
				t,
				abs(f.y - f.home_y) <= FIREFLY_DRIFT_Y,
				"a firefly must hang in the air over its mark, and one is %v cells off",
				f.y - f.home_y,
			)
		}
	}
}

@(test)
test_a_firefly_lights_the_bank_it_hangs_over :: proc(t: ^testing.T) {
	s: Sim
	if !firefly_test_sim(t, &s) do return
	defer sim_unload(&s)

	sim_step_player(&s, {}, false)

	f := s.flies.flies[0]
	x := i32(math.floor(f.x))
	y := i32(math.floor(f.y))

	// Read what the swarm itself throws, not what falls on the pond:
	// the day lights the whole of an open field, so `light_lux` there
	// would answer for the fireflies whether they burned or not.
	here := light_live_lux(&s.light, x, y)
	away := light_live_lux(&s.light, x, y - 8 * FIREFLY_REACH * LIGHT_CELL)

	testing.expectf(t, here > 0, "the air a firefly hangs in must be lit, got %d", here)
	testing.expectf(t, away == 0, "and the gloom well above the pond must stay dark, got %d", away)
}

@(test)
test_a_firefly_leaves_no_light_behind_it :: proc(t: ^testing.T) {
	s: Sim
	if !firefly_test_sim(t, &s) do return
	defer sim_unload(&s)

	sim_step_player(&s, {}, false)

	f := s.flies.flies[0]
	x := i32(math.floor(f.x))
	y := i32(math.floor(f.y))
	if !testing.expect(t, light_live_lux(&s.light, x, y) > 0, "the swarm must light its own air first") do return

	for i in 0 ..< int(s.flies.count) {
		s.flies.flies[i].home_y -= 8 * FIREFLY_REACH * LIGHT_CELL
	}
	sim_step_player(&s, {}, false)

	behind := light_live_lux(&s.light, x, y)
	testing.expectf(
		t,
		behind == 0,
		"a firefly drops no crystal, so the air it leaves must go dark again, and it holds %d",
		behind,
	)
}

@(test)
test_the_swarm_never_outshines_the_trail_or_the_orb :: proc(t: ^testing.T) {
	s: Sim
	if !firefly_test_sim(t, &s) do return
	defer sim_unload(&s)

	for _ in 0 ..< 120 do sim_step_player(&s, {}, false)

	power := light_lumens(s.world.materials, s.world.materials.firefly)
	for i in 0 ..< int(s.flies.count) {
		f := s.flies.flies[i]
		lux := light_live_lux(&s.light, i32(math.floor(f.x)), i32(math.floor(f.y)))
		testing.expectf(
			t,
			lux <= power,
			"no firefly may burn past the luminosity of Firefly_Light, and one lights its own cell to %d against %d",
			lux, power,
		)
	}
}

@(test)
test_the_swarm_moves_the_same_way_every_time :: proc(t: ^testing.T) {
	walk :: proc(t: ^testing.T) -> (x, y: f32) {
		s: Sim
		if !firefly_test_sim(t, &s) do return 0, 0
		defer sim_unload(&s)

		for _ in 0 ..< 300 do sim_step_player(&s, {.Right}, false)
		return s.flies.flies[0].x, s.flies.flies[0].y
	}

	ax, ay := walk(t)
	bx, by := walk(t)
	testing.expectf(
		t,
		ax == bx && ay == by,
		"the same ticks must put a firefly in the same place, got %v,%v and %v,%v",
		ax,
		ay,
		bx,
		by,
	)
}
