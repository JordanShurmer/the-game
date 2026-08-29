package game

import testing "check"
import rl "vendor:raylib"

// A sparkle is the light the mix throws off: a dot that rises, flashes, and
// is gone. It is a ring on the sandbox, beside the ring of bangs, built the
// same way for the same reason: the cells write themselves, and the ring is
// what the light throws and the eye draws. See docs/alchemy.md, "The ring".

SPARKLE_MAX :: 64 // sparkles the world remembers at once, for the light

SPARKLE_REACH :: 5 // the smallest light in the world; brightness is not reach
SPARKLE_FALL :: Light_Fall{open = 100, open_diag = 85, dense = 55, dense_diag = 36}

SPARKLE_HALO :: 3
SPARKLE_BLAZE :: 0
SPARKLE_PEAK :: 0.9
SPARKLE_GLOW :: rl.Color{223, 243, 255, 255}
SPARKLE_CORE :: rl.Color{255, 255, 255, 255}

SPARKLE_SPENT :: i16(-1) // the slot is free, and the light has cleared its box

Spark :: struct {
	x, y: i32,
	life: i16,
	seed: u8,
	lit:  bool,
	lx, ly: i32,
}
#assert(size_of(Spark) == 20)

Spark_Ring :: struct {
	sparks: [SPARKLE_MAX]Spark,
	next:   i32,
}

// A zero Spark_Ring holds SPARKLE_MAX sparks at the origin with no life
// left, so a ring is emptied before it is read.
spark_forget_all :: proc(r: ^Spark_Ring) {
	for &sp in r.sparks do sp = Spark{life = SPARKLE_SPENT}
	r.next = 0
}

spark_add :: proc(sb: ^Sandbox, table: Material_Table, x, y: i32) {
	life := table.materials[table.sparkle].lifetime
	if life <= 0 do return

	seed := u8(sandbox_chance(sb, x, y, .Spark_Seed))
	r := &sb.sparks
	r.sparks[r.next] = Spark{x = x, y = y, life = i16(min(life, 32767)), seed = seed}
	r.next = (r.next + 1) % SPARKLE_MAX
}

// One tick of every sparkle. A sparkle that has run out keeps its place for
// one more tick, so the light has a tick to clear the box it lit last.
spark_age :: proc(r: ^Spark_Ring) {
	for &sp in r.sparks {
		if sp.life >= 0 do sp.life -= 1
	}
}

// The light a sparkle throws. It holds near its peak for the first third of
// its life and falls away as the square of what is left after that, the way
// bang_power does: it snaps on and gutters out. A seed byte jitters the
// brightness 0.72 to 1.0, so a swarm of them shimmers instead of pulsing as
// one.
spark_power :: proc(table: Material_Table, sp: Spark) -> u8 {
	m := table.materials[table.sparkle]
	if sp.life <= 0 || m.lifetime <= 0 do return 0

	full := f32(m.lifetime)
	third := full / 3
	elapsed := full - f32(sp.life)

	frac := f32(1)
	if elapsed > third {
		remain := f32(sp.life) / (full - third)
		frac = remain * remain
	}

	jitter := 0.72 + 0.28 * f32(sp.seed) / 255
	return u8(f32(m.luminosity) * frac * jitter)
}

@(test)
test_the_ring_keeps_the_newest_sparkles :: proc(t: ^testing.T) {
	table, ok := load_materials("data/materials.txt")
	defer destroy_material_table(table)
	if !testing.expect(t, ok, "materials must load") do return

	sb: Sandbox
	spark_forget_all(&sb.sparks)
	for i in i32(0) ..< SPARKLE_MAX + 3 do spark_add(&sb, table, i, i)

	newest := false
	oldest := false
	for sp in sb.sparks.sparks {
		if sp.x == SPARKLE_MAX + 2 do newest = true
		if sp.x == 0 do oldest = true
	}
	testing.expect(t, newest, "the newest sparkle must be in the ring")
	testing.expect(t, !oldest, "and the oldest must have been written over")
}

@(test)
test_a_sparkle_only_ever_fades_and_ends_dark :: proc(t: ^testing.T) {
	table, ok := load_materials("data/materials.txt")
	defer destroy_material_table(table)
	if !testing.expect(t, ok, "materials must load") do return

	sb: Sandbox
	spark_forget_all(&sb.sparks)
	spark_add(&sb, table, 0, 0)

	last := u8(255)
	for _ in 0 ..< int(table.materials[table.sparkle].lifetime) {
		power := spark_power(table, sb.sparks.sparks[0])
		testing.expectf(t, power <= last, "a sparkle must only ever fade, got %d after %d", power, last)
		last = power
		spark_age(&sb.sparks)
	}
	testing.expect(t, last == 0 || spark_power(table, sb.sparks.sparks[0]) == 0, "and end dark")
}

@(test)
test_a_sparkle_s_life_is_very_brief :: proc(t: ^testing.T) {
	table, ok := load_materials("data/materials.txt")
	defer destroy_material_table(table)
	if !testing.expect(t, ok, "materials must load") do return

	sb: Sandbox
	spark_forget_all(&sb.sparks)
	spark_add(&sb, table, 0, 0)

	ticks := 0
	for sb.sparks.sparks[0].life >= 0 {
		spark_age(&sb.sparks)
		ticks += 1
		if ticks > 100 do break
	}
	testing.expectf(t, ticks <= 12, "a sparkle must be very brief, and one lived %d ticks", ticks)
}

@(test)
test_attor_meeting_water_leaves_a_live_sparkle_in_the_ring :: proc(t: ^testing.T) {
	table, ok := load_materials("data/materials.txt")
	defer destroy_material_table(table)
	if !testing.expect(t, ok, "materials must load") do return

	attor, aok := find_material_index(table, "Attor")
	water, wok := find_material_index(table, "Water")
	if !testing.expect(t, aok && wok, "Attor and Water must exist") do return

	sb, sok := sandbox_make(20, 20, 1)
	if !testing.expect(t, sok, "sandbox must build") do return
	defer sandbox_destroy(&sb)

	for y in i32(0) ..< 10 {
		for x in i32(0) ..< 20 {
			sb.cells[sandbox_index(&sb, x, y)] = Cell(attor)
		}
	}
	for y in i32(10) ..< 20 {
		for x in i32(0) ..< 20 {
			sb.cells[sandbox_index(&sb, x, y)] = Cell(water)
		}
	}
	sandbox_mark_all(&sb)

	found := false
	for _ in 0 ..< 50 {
		sandbox_step(&sb, table)
		for sp in sb.sparks.sparks {
			if sp.life >= 0 do found = true
		}
		if found do break
	}
	testing.expect(t, found, "the mix must throw at least one live sparkle into the ring")
}
