package game

import "core:math"
import "core:testing"
import rl "vendor:raylib"

FIREFLY_MAX :: 24
FIREFLY_PER_POND :: 7

// A firefly is a light with no body, and the light it carries is the
// Firefly_Light material. See docs/lighting.md, "Every light is a material";
// test_the_lights_of_the_world_are_ordered holds it under the trail he leaves.
FIREFLY_REACH :: 9
FIREFLY_FALL :: Light_Fall{open = 176, open_diag = 150, dense = 96, dense_diag = 64}

FIREFLY_HOVER :: 8.0
FIREFLY_SPREAD :: 0.82
FIREFLY_RISE :: 7.0
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

firefly_gather :: proc(world: World) -> (swarm: Firefly_Swarm) {
	for i in 0 ..< int(world.pond_count) {
		p := world.ponds[i]

		for k in 0 ..< FIREFLY_PER_POND {
			if swarm.count >= FIREFLY_MAX do break

			h := wang_hash(world.seed, FIREFLY_SALT, p.x + i32(k), p.y)
			across := (f32(k) + 0.5) * 2 / FIREFLY_PER_POND - 1

			swarm.flies[swarm.count] = Firefly {
				home_x  = f32(p.x) + across * f32(p.rx) * FIREFLY_SPREAD,
				home_y  = f32(p.y) - FIREFLY_HOVER - f32(h & 7) * FIREFLY_RISE / 8,
				rate_x  = firefly_rate(h >> 8),
				rate_y  = firefly_rate(h >> 16),
				phase_x = u8(h >> 24),
				phase_y = u8(h >> 32),
				pulse   = u8(h >> 40),
			}
			swarm.count += 1
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

	p := s.world.ponds[0]
	reach_x := f32(p.rx) * FIREFLY_SPREAD + FIREFLY_DRIFT_X
	lowest := f32(p.y) - FIREFLY_HOVER - FIREFLY_RISE - FIREFLY_DRIFT_Y

	for _ in 0 ..< 900 {
		firefly_step(&s.flies)

		for i in 0 ..< int(s.flies.count) {
			f := s.flies.flies[i]
			testing.expectf(
				t,
				abs(f.x - f32(p.x)) <= reach_x,
				"a firefly must stay over its own pond, and one is %v cells from the middle of it",
				f.x - f32(p.x),
			)
			testing.expectf(
				t,
				f.y < f32(p.y) && f.y > lowest,
				"a firefly must hang in the air over the water, and one is at y=%v with the water at %d",
				f.y,
				p.y,
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
