package game

import testing "check"
import rl "vendor:raylib"

// A bang is an explosion the world remembers: the place a blast went off and
// what is left of the life of the material it is made of. The blast itself
// writes the cells; the bang is what the light throws and what the eye draws,
// so every explosion lights the cave it goes off in, whatever set it off.
//
// See docs/physics.md, "Explosions", and docs/lighting.md, "Every light is a
// material".

BANG_MAX :: 16 // bangs the world remembers at once

BANG_REACH :: 34
BANG_FALL :: Light_Fall{open = 220, open_diag = 204, dense = 112, dense_diag = 78}

BANG_HALO :: 28
BANG_BLAZE :: 6
BANG_PEAK :: 0.95
BANG_GLOW :: rl.Color{255, 140, 40, 255}
BANG_CORE :: rl.Color{255, 250, 230, 255}

BANG_SPENT :: i16(-1) // the slot is free, and the light has cleared its box

Bang :: struct {
	x, y: i32,
	life: i16,
}
#assert(size_of(Bang) == 12)

Bang_Ring :: struct {
	bangs: [BANG_MAX]Bang,
	next:  i32,
}

// A zero Bang_Ring holds BANG_MAX bangs at the origin with no life left, so a
// ring is emptied before it is read.
bang_forget_all :: proc(r: ^Bang_Ring) {
	for &b in r.bangs do b = Bang{life = BANG_SPENT}
	r.next = 0
}

bang_add :: proc(r: ^Bang_Ring, table: Material_Table, x, y: i32) {
	life := table.materials[table.blast].lifetime
	if life <= 0 do return

	r.bangs[r.next] = Bang{x = x, y = y, life = i16(min(life, 32767))}
	r.next = (r.next + 1) % BANG_MAX
}

// One tick of every bang. A bang that has run out keeps its place for one
// more tick, so the light has a tick to clear the box it lit last.
bang_age :: proc(r: ^Bang_Ring) {
	for &b in r.bangs {
		if b.life >= 0 do b.life -= 1
	}
}

// The light a bang throws, shaped by what is left of its life. The count runs
// down evenly and the square holds the brightness near its peak for the first
// half, so a bang snaps bright the instant it goes off and gutters at the end.
bang_power :: proc(table: Material_Table, b: Bang) -> u8 {
	blast := table.materials[table.blast]
	if b.life <= 0 || blast.lifetime <= 0 do return 0

	frac := f32(b.life) / f32(blast.lifetime)
	return u8(f32(blast.luminosity) * frac * frac)
}

@(test)
test_a_bang_lives_as_long_as_the_material_it_is_made_of :: proc(t: ^testing.T) {
	table, ok := load_materials("data/materials.txt")
	defer destroy_material_table(table)
	if !testing.expect(t, ok, "materials must load") do return

	life := table.materials[table.blast].lifetime

	r: Bang_Ring
	bang_forget_all(&r)
	bang_add(&r, table, 10, 20)

	testing.expectf(
		t, r.bangs[0].life == i16(life),
		"a bang must start with the whole life of the blast material, got %d against %d",
		r.bangs[0].life, life,
	)
	testing.expectf(
		t, bang_power(table, r.bangs[0]) == table.materials[table.blast].luminosity,
		"a bang must throw the whole light of the blast material the tick it goes off, got %d",
		bang_power(table, r.bangs[0]),
	)

	for _ in 0 ..< int(life) do bang_age(&r)
	testing.expect(t, bang_power(table, r.bangs[0]) == 0, "a spent bang must throw no light")

	testing.expectf(
		t, r.bangs[0].life == 0,
		"a spent bang must keep its place for one tick, so the light can clear the box it lit, got %d",
		r.bangs[0].life,
	)

	bang_age(&r)
	testing.expect(t, r.bangs[0].life == BANG_SPENT, "and then the slot must be free")
}

@(test)
test_a_bang_fades_and_never_brightens :: proc(t: ^testing.T) {
	table, ok := load_materials("data/materials.txt")
	defer destroy_material_table(table)
	if !testing.expect(t, ok, "materials must load") do return

	r: Bang_Ring
	bang_forget_all(&r)
	bang_add(&r, table, 0, 0)

	last := u8(255)
	for _ in 0 ..< int(table.materials[table.blast].lifetime) {
		power := bang_power(table, r.bangs[0])
		testing.expectf(t, power <= last, "a bang must only ever fade, got %d after %d", power, last)
		last = power
		bang_age(&r)
	}
	testing.expect(t, last == 0 || bang_power(table, r.bangs[0]) == 0, "and end dark")
}

@(test)
test_the_ring_keeps_the_newest_bangs :: proc(t: ^testing.T) {
	table, ok := load_materials("data/materials.txt")
	defer destroy_material_table(table)
	if !testing.expect(t, ok, "materials must load") do return

	r: Bang_Ring
	bang_forget_all(&r)
	for i in i32(0) ..< BANG_MAX + 3 do bang_add(&r, table, i, i)

	newest := false
	oldest := false
	for b in r.bangs {
		if b.x == BANG_MAX + 2 do newest = true
		if b.x == 0 do oldest = true
	}
	testing.expect(t, newest, "the newest bang must be in the ring")
	testing.expect(t, !oldest, "and the oldest must have been written over")
}
