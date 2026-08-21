package game

import "core:math"
import "core:mem"
import "core:testing"
import rl "vendor:raylib"

LIGHT_CELL :: 4
LIGHT_W :: SANDBOX_PLAY_SIZE / LIGHT_CELL
LIGHT_H :: SANDBOX_PLAY_SIZE / LIGHT_CELL
LIGHT_SAMPLES :: LIGHT_W * LIGHT_H
LIGHT_QUEUE :: 1 << 16

LIGHT_FAINT :: 2
LIGHT_RESPONSE_GAMMA :: 0.65

LIGHT_ORB_DX :: 6.0
LIGHT_ORB_DY :: -19.0
LIGHT_ORB_MIRROR :: -0.5
LIGHT_ORB_SEEK :: 8

LIGHT_ORB_POWER :: 255
LIGHT_ORB_REACH :: 27
LIGHT_CRYSTAL_POWER :: 168
LIGHT_CRYSTAL_REACH :: 18

#assert(LIGHT_CRYSTAL_POWER < LIGHT_ORB_POWER, "the trail he leaves must never outshine the orb he carries")

Light_Fall :: struct {
	open:       u8,
	open_diag:  u8,
	dense:      u8,
	dense_diag: u8,
}

LIGHT_ORB_FALL :: Light_Fall{open = 212, open_diag = 196, dense = 108, dense_diag = 75}
LIGHT_CRYSTAL_FALL :: Light_Fall{open = 193, open_diag = 172, dense = 108, dense_diag = 75}

LIGHT_CRYSTALS :: 1024
LIGHT_DROP_STRIDE :: 21.0

LIGHT_GLOOM_R :: 30
LIGHT_GLOOM_G :: 30
LIGHT_GLOOM_B :: 42
LIGHT_GLOOM_LIFT_R :: 3
LIGHT_GLOOM_LIFT_G :: 3
LIGHT_GLOOM_LIFT_B :: 6

LIGHT_HAZE_R :: 78
LIGHT_HAZE_G :: 64
LIGHT_HAZE_B :: 38

LIGHT_BLOOM_KNEE :: 96
LIGHT_BLOOM_STRENGTH :: 150
LIGHT_BLOOM :: rl.Color{255, 240, 206, 255}

LIGHT_ORB_HALO :: 10
LIGHT_ORB_BLAZE :: 3
LIGHT_ORB_PEAK :: 0.92
LIGHT_CRYSTAL_HALO :: 5
LIGHT_CRYSTAL_BLAZE :: 0
LIGHT_CRYSTAL_PEAK :: 0.62

LIGHT_CORE :: rl.Color{255, 251, 233, 255}
LIGHT_GLOW :: rl.Color{255, 208, 122, 255}
LIGHT_TWINKLE_HZ :: 1.7

LIGHT_SALT_CRYSTAL :: 0x0000_0000_0000_0011

Crystal :: struct {
	x, y:    f32,
	twinkle: u8,
}

#assert(size_of(Crystal) == 12)

Light :: struct {
	stat:     []u8,
	live:     []u8,
	flood:    []i32,
	crystals: []Crystal,

	origin_x: i32,
	origin_y: i32,

	live_x:  i32,
	live_y:  i32,
	live_on: bool,

	count: i32,
	next:  i32,

	last_x:  f32,
	last_y:  f32,
	dropped: bool,

	seed: u64,
}

light_make :: proc(seed: u64) -> Light {
	return Light {
		stat = make([]u8, LIGHT_SAMPLES),
		live = make([]u8, LIGHT_SAMPLES),
		flood = make([]i32, LIGHT_QUEUE),
		crystals = make([]Crystal, LIGHT_CRYSTALS),
		seed = seed,
	}
}

light_destroy :: proc(l: ^Light) {
	delete(l.stat)
	delete(l.live)
	delete(l.flood)
	delete(l.crystals)
	l^ = {}
}

light_move :: proc(l: ^Light, origin_x, origin_y: i32) {
	if l.stat == nil do return
	l.origin_x = origin_x
	l.origin_y = origin_y
	mem.zero_slice(l.stat)
	mem.zero_slice(l.live)
	l.live_on = false
	l.count = 0
	l.next = 0
	l.dropped = false
}

light_follow :: proc(l: ^Light, x, y: i32) {
	if l.stat == nil do return
	origin_x := floor_div(x, SANDBOX_PLAY_SIZE) * SANDBOX_PLAY_SIZE
	origin_y := floor_div(y, SANDBOX_PLAY_SIZE) * SANDBOX_PLAY_SIZE
	if l.origin_x == origin_x && l.origin_y == origin_y do return
	light_move(l, origin_x, origin_y)
}

light_orb_at :: proc(p: Player) -> (x, y: f32) {
	return p.x + LIGHT_ORB_MIRROR + f32(p.facing) * LIGHT_ORB_DX, p.y + LIGHT_ORB_DY
}

light_orb_source :: proc(t: Terrain, p: Player) -> (x, y: i32) {
	ox, oy := light_orb_at(p)
	cx, cy := player_centre(p)

	for i in 0 ..= i32(LIGHT_ORB_SEEK) {
		w := f32(i) / f32(LIGHT_ORB_SEEK)
		x = i32(math.floor(ox + (f32(cx) - ox) * w))
		y = i32(math.floor(oy + (f32(cy) - oy) * w))
		if !player_solid_at(t, x, y) do return x, y
	}
	return x, y
}

light_slot :: #force_inline proc(d: i32) -> i32 {
	return floor_div(d, LIGHT_CELL)
}

light_dense_at :: proc(l: ^Light, t: Terrain, lx, ly: i32) -> bool {
	wx := l.origin_x + lx * LIGHT_CELL + LIGHT_CELL / 2
	wy := l.origin_y + ly * LIGHT_CELL + LIGHT_CELL / 2
	return player_solid_at(t, wx, wy)
}

light_clear_box :: proc(grid: []u8, lx, ly, reach: i32) {
	x0 := max(lx - reach, 0)
	y0 := max(ly - reach, 0)
	x1 := min(lx + reach, LIGHT_W - 1)
	y1 := min(ly + reach, LIGHT_H - 1)

	for y in y0 ..= y1 {
		row := grid[int(y) * LIGHT_W + int(x0):][:x1 - x0 + 1]
		mem.zero_slice(row)
	}
}

light_flood :: proc(l: ^Light, grid: []u8, t: Terrain, wx, wy: i32, power: u8, reach: i32, fall: Light_Fall) {
	start_x := light_slot(wx - l.origin_x)
	start_y := light_slot(wy - l.origin_y)
	if start_x < 0 || start_y < 0 || start_x >= LIGHT_W || start_y >= LIGHT_H do return

	x0 := max(start_x - reach, 0)
	y0 := max(start_y - reach, 0)
	x1 := min(start_x + reach, LIGHT_W - 1)
	y1 := min(start_y + reach, LIGHT_H - 1)

	start := int(start_y) * LIGHT_W + int(start_x)
	if grid[start] >= power do return
	grid[start] = power

	l.flood[0] = i32(start)
	head, tail := 0, 1

	for head < tail {
		at := int(l.flood[head])
		head += 1

		value := u32(grid[at])
		if value <= LIGHT_FAINT do continue

		ax := i32(at % LIGHT_W)
		ay := i32(at / LIGHT_W)
		dense := at != start && light_dense_at(l, t, ax, ay)

		for dy in i32(-1) ..= 1 {
			ny := ay + dy
			if ny < y0 || ny > y1 do continue

			for dx in i32(-1) ..= 1 {
				if dx == 0 && dy == 0 do continue
				nx := ax + dx
				if nx < x0 || nx > x1 do continue

				step: u32
				if dx != 0 && dy != 0 {
					step = dense ? u32(fall.dense_diag) : u32(fall.open_diag)
				} else {
					step = dense ? u32(fall.dense) : u32(fall.open)
				}

				next := value * step / 256
				if next <= LIGHT_FAINT do continue

				ni := int(ny) * LIGHT_W + int(nx)
				if u32(grid[ni]) >= next do continue
				grid[ni] = u8(next)

				if tail >= len(l.flood) do continue
				l.flood[tail] = i32(ni)
				tail += 1
			}
		}
	}
}

light_corner :: #force_inline proc(l: ^Light, lx, ly: i32) -> u32 {
	if lx < 0 || ly < 0 || lx >= LIGHT_W || ly >= LIGHT_H do return 0
	i := int(ly) * LIGHT_W + int(lx)
	return u32(max(l.stat[i], l.live[i]))
}

light_response: [256]u8

@(init)
light_response_init :: proc "contextless" () {
	for i in LIGHT_FAINT + 1 ..< 256 {
		light_response[i] = u8(255 * math.pow(f32(i - LIGHT_FAINT) / f32(255 - LIGHT_FAINT), LIGHT_RESPONSE_GAMMA))
	}
}

light_lux :: proc(l: ^Light, wx, wy: i32) -> u8 {
	if l.stat == nil do return 255

	fx := wx - l.origin_x - LIGHT_CELL / 2
	fy := wy - l.origin_y - LIGHT_CELL / 2
	lx := light_slot(fx)
	ly := light_slot(fy)
	tx := u32(fx - lx * LIGHT_CELL)
	ty := u32(fy - ly * LIGHT_CELL)

	top := light_corner(l, lx, ly) * (LIGHT_CELL - tx) + light_corner(l, lx + 1, ly) * tx
	bottom := light_corner(l, lx, ly + 1) * (LIGHT_CELL - tx) + light_corner(l, lx + 1, ly + 1) * tx

	return u8((top * (LIGHT_CELL - ty) + bottom * ty) / (LIGHT_CELL * LIGHT_CELL))
}

light_shade :: proc(c: rl.Color, lux: u8) -> rl.Color {
	mix :: #force_inline proc(dark, lit, l: u32) -> u32 {
		return (dark * (255 - l) + lit * l) / 255
	}
	gloom :: #force_inline proc(v: u32, keep, lift: u32) -> u32 {
		return v * keep / 256 + lift
	}
	haze :: #force_inline proc(v: u32, l, fill: u32) -> u32 {
		return v + fill * l * (255 - v) / (255 * 255)
	}

	l := u32(light_response[lux])
	r := haze(mix(gloom(u32(c.r), LIGHT_GLOOM_R, LIGHT_GLOOM_LIFT_R), u32(c.r), l), l, LIGHT_HAZE_R)
	g := haze(mix(gloom(u32(c.g), LIGHT_GLOOM_G, LIGHT_GLOOM_LIFT_G), u32(c.g), l), l, LIGHT_HAZE_G)
	b := haze(mix(gloom(u32(c.b), LIGHT_GLOOM_B, LIGHT_GLOOM_LIFT_B), u32(c.b), l), l, LIGHT_HAZE_B)

	if lux > LIGHT_BLOOM_KNEE {
		over := u32(lux - LIGHT_BLOOM_KNEE) * LIGHT_BLOOM_STRENGTH / (255 - LIGHT_BLOOM_KNEE)
		r = mix(r, u32(LIGHT_BLOOM.r), over)
		g = mix(g, u32(LIGHT_BLOOM.g), over)
		b = mix(b, u32(LIGHT_BLOOM.b), over)
	}

	return rl.Color{u8(min(r, 255)), u8(min(g, 255)), u8(min(b, 255)), 255}
}

light_step :: proc(l: ^Light, t: Terrain, p: Player, flies: ^Firefly_Swarm = nil, pots: ^Pot_Bag = nil) {
	if l.stat == nil do return
	light_drop(l, t, p)
	light_throw(l, t, p, flies, pots)
}

light_drop :: proc(l: ^Light, t: Terrain, p: Player) {
	x, y := light_orb_source(t, p)
	fx, fy := f32(x), f32(y)

	if l.dropped {
		dx := fx - l.last_x
		dy := fy - l.last_y
		if dx * dx + dy * dy < LIGHT_DROP_STRIDE * LIGHT_DROP_STRIDE do return
	}
	l.last_x = fx
	l.last_y = fy
	l.dropped = true

	l.crystals[l.next] = Crystal{x = fx, y = fy, twinkle = u8(wang_hash(l.seed, LIGHT_SALT_CRYSTAL, x, y))}
	l.next = (l.next + 1) % LIGHT_CRYSTALS
	l.count = min(l.count + 1, LIGHT_CRYSTALS)

	light_flood(l, l.stat, t, x, y, LIGHT_CRYSTAL_POWER, LIGHT_CRYSTAL_REACH, LIGHT_CRYSTAL_FALL)
}

light_throw :: proc(l: ^Light, t: Terrain, p: Player, flies: ^Firefly_Swarm = nil, pots: ^Pot_Bag = nil) {
	if l.live_on do light_clear_box(l.live, l.live_x, l.live_y, LIGHT_ORB_REACH)
	light_forget_flies(l, flies)
	light_forget_pots(l, pots)

	x, y := light_orb_source(t, p)
	l.live_x = light_slot(x - l.origin_x)
	l.live_y = light_slot(y - l.origin_y)
	l.live_on = true

	light_flood(l, l.live, t, x, y, LIGHT_ORB_POWER, LIGHT_ORB_REACH, LIGHT_ORB_FALL)
	light_throw_flies(l, t, flies)
	light_throw_pots(l, t, pots)
}

@(private = "file")
light_forget_flies :: proc(l: ^Light, flies: ^Firefly_Swarm) {
	if flies == nil do return

	for i in 0 ..< int(flies.count) {
		f := &flies.flies[i]
		if !f.lit do continue
		light_clear_box(l.live, f.lx, f.ly, FIREFLY_REACH)
		f.lit = false
	}
}

@(private = "file")
light_throw_flies :: proc(l: ^Light, t: Terrain, flies: ^Firefly_Swarm) {
	if flies == nil do return

	for i in 0 ..< int(flies.count) {
		f := &flies.flies[i]
		x := i32(math.floor(f.x))
		y := i32(math.floor(f.y))

		lx := light_slot(x - l.origin_x)
		ly := light_slot(y - l.origin_y)
		if lx < 0 || ly < 0 || lx >= LIGHT_W || ly >= LIGHT_H do continue

		light_flood(l, l.live, t, x, y, firefly_power(f^, flies.clock), FIREFLY_REACH, FIREFLY_FALL)
		f.lx = lx
		f.ly = ly
		f.lit = true
	}
}

@(private = "file")
light_forget_pots :: proc(l: ^Light, pots: ^Pot_Bag) {
	if pots == nil do return

	for i in 0 ..< int(pots.count) {
		p := &pots.pots[i]
		if !p.lit do continue
		light_clear_box(l.live, p.lx, p.ly, POT_FLASH_REACH)
		p.lit = false
	}
}

@(private = "file")
light_throw_pots :: proc(l: ^Light, t: Terrain, pots: ^Pot_Bag) {
	if pots == nil do return

	for i in 0 ..< int(pots.count) {
		p := &pots.pots[i]
		if !p.live || p.flash == 0 do continue

		x := i32(math.floor(p.x))
		y := i32(math.floor(p.y))

		lx := light_slot(x - l.origin_x)
		ly := light_slot(y - l.origin_y)
		if lx < 0 || ly < 0 || lx >= LIGHT_W || ly >= LIGHT_H do continue

		light_flood(l, l.live, t, x, y, pot_flash_power(p^), POT_FLASH_REACH, POT_FLASH_FALL)
		p.lx = lx
		p.ly = ly
		p.lit = true
	}
}

light_fall_reach :: proc(power: u8, fall: Light_Fall) -> i32 {
	value := u32(power)
	steps := i32(0)
	for value > LIGHT_FAINT {
		value = value * u32(fall.open) / 256
		steps += 1
	}
	return steps
}

light_halo_fade :: proc(away, halo: i32, peak: f32) -> f32 {
	if away > halo * halo do return 0
	left := 1 - f32(away) / f32(halo * halo)
	return peak * left * left
}

light_crystal_glow :: proc(c: Crystal, clock: f64) -> f32 {
	phase := f32(clock) * LIGHT_TWINKLE_HZ + f32(c.twinkle) * (2 * math.PI / 256)
	return 0.75 + 0.25 * math.sin(phase)
}

@(private = "file")
light_test_player :: proc(x, y: f32, facing: i8) -> Player {
	return Player{x = x, y = y, facing = facing, on_ground = true}
}

@(private = "file")
light_fill_box :: proc(sb: ^Sandbox, x0, y0, x1, y1: i32, c: Cell) {
	for y in y0 ..= y1 {
		for x in x0 ..= x1 {
			if !sandbox_in_bounds(sb, x, y) do continue
			sb.cells[sandbox_index(sb, x, y)] = c
		}
	}
}

@(test)
test_every_reach_outlasts_the_falloff_it_bounds :: proc(t: ^testing.T) {
	orb := light_fall_reach(LIGHT_ORB_POWER, LIGHT_ORB_FALL)
	testing.expectf(
		t, orb <= LIGHT_ORB_REACH,
		"the orb still burns %d samples out and its box stops at %d, which draws a square of light and not a pool",
		orb, i32(LIGHT_ORB_REACH),
	)

	crystal := light_fall_reach(LIGHT_CRYSTAL_POWER, LIGHT_CRYSTAL_FALL)
	testing.expectf(
		t, crystal <= LIGHT_CRYSTAL_REACH,
		"a crystal still burns %d samples out and its box stops at %d, which draws a square of light and not a pool",
		crystal, i32(LIGHT_CRYSTAL_REACH),
	)

	flash := light_fall_reach(POT_FLASH_POWER, POT_FLASH_FALL)
	testing.expectf(
		t, flash <= POT_FLASH_REACH,
		"a bang still burns %d samples out and its box stops at %d, which draws a square of light and not a pool",
		flash, i32(POT_FLASH_REACH),
	)
}

@(test)
test_the_orb_light_starts_where_the_sheet_draws_the_orb :: proc(t: ^testing.T) {
	sheet, result := load_sprite_sheet(SPRITE_SHEET_PATH)
	if !testing.expectf(t, result.err == .None, "the shipped sheet must load, got %v", result.err) do return
	defer destroy_sprite_sheet(sheet)

	for facing in ([]i8{1, -1}) {
		p := light_test_player(100, 100, facing)
		ox, oy := light_orb_at(p)
		frame_x, frame_y := sprite_frame_origin(p)

		fx := i32(math.floor(ox)) - frame_x
		fy := i32(math.floor(oy)) - frame_y
		got := sprite_pixel(sheet, .Idle, 0, facing, fx, fy)

		orb := got.r == LIGHT_GLOW.r && got.g == LIGHT_GLOW.g && got.b == LIGHT_GLOW.b
		core := got.r == LIGHT_CORE.r && got.g == LIGHT_CORE.g && got.b == LIGHT_CORE.b
		testing.expectf(
			t, orb || core,
			"facing %d puts the light at frame (%d,%d), where the sheet draws %v and not the orb",
			facing, fx, fy, got,
		)
	}
}

@(test)
test_the_gloom_cools_a_colour_and_never_swallows_it :: proc(t: ^testing.T) {
	stone := rl.Color{150, 140, 130, 255}

	dark := light_shade(stone, 0)
	lit := light_shade(stone, 255)

	testing.expectf(
		t, dark.r < stone.r / 2 && dark.g < stone.g / 2 && dark.b < stone.b / 2,
		"the gloom must take most of the colour, got %v from %v", dark, stone,
	)
	testing.expectf(
		t, dark.r > 0 && dark.g > 0 && dark.b > 0,
		"the gloom must leave a shape to read, not a black hole, got %v", dark,
	)
	testing.expectf(
		t, dark.b > dark.r,
		"warm stone must go blue in the dark, or the shadow reads as dirt and not as night, got %v", dark,
	)
	testing.expectf(
		t, lit.r > stone.r && lit.g > stone.g && lit.b > stone.b,
		"what the orb stands on must be bleached toward the orb, got %v from %v", lit, stone,
	)
}

@(test)
test_light_outside_the_grid_reads_as_the_gloom :: proc(t: ^testing.T) {
	l := light_make(1)
	defer light_destroy(&l)

	testing.expect(t, light_lux(&l, -9000, -9000) == 0, "a cell the grid does not hold must hold no light")
	testing.expect(t, light_lux(&l, 0, 0) == 0, "a cell nothing has lit must hold no light")
}

@(test)
test_rock_stops_the_light_and_a_corridor_carries_it :: proc(t: ^testing.T) {
	s: Sim
	if !testing.expect(t, sim_load(&s) == .None, "the world must load") do return
	defer sim_unload(&s)

	rock, found := sim_material_index(&s, "Rock")
	if !testing.expect(t, found, "Rock must exist") do return

	sim_open_sandbox(&s, 512, 512, 0, 0, 1, 0)
	light_move(&s.light, 0, 0)

	light_fill_box(&s.sandbox, 0, 0, 511, 511, Cell(rock))
	light_fill_box(&s.sandbox, 0, 248, 511, 263, MATERIAL_AIR)

	terrain := Terrain{world = s.world, sandbox = &s.sandbox}
	light_flood(&s.light, s.light.live, terrain, 32, 256, LIGHT_ORB_POWER, LIGHT_ORB_REACH, LIGHT_ORB_FALL)

	source := light_lux(&s.light, 32, 256)
	along := light_lux(&s.light, 100, 256)
	through := light_lux(&s.light, 32, 200)

	testing.expectf(t, source > 200, "the cell the orb sits in must be near full light, got %d", source)
	testing.expectf(
		t, light_response[along] > 0,
		"68 cells down an open corridor must still be lit, got %d", along,
	)
	testing.expectf(
		t, along > through,
		"the corridor must carry the light further than the rock does, got %d along and %d through",
		along, through,
	)
	testing.expectf(
		t, through == 0,
		"56 cells of rock must swallow the light whole, got %d", through,
	)
}

@(test)
test_a_flood_never_leaves_the_box_its_reach_allows :: proc(t: ^testing.T) {
	s: Sim
	if !testing.expect(t, sim_load(&s) == .None, "the world must load") do return
	defer sim_unload(&s)

	sim_open_sandbox(&s, 512, 512, 0, 0, 1, 0)
	light_move(&s.light, 0, 0)
	light_fill_box(&s.sandbox, 0, 0, 511, 511, MATERIAL_AIR)

	terrain := Terrain{world = s.world, sandbox = &s.sandbox}
	light_flood(&s.light, s.light.live, terrain, 1024, 1024, LIGHT_ORB_POWER, LIGHT_ORB_REACH, LIGHT_ORB_FALL)

	centre_x := light_slot(1024)
	centre_y := light_slot(1024)

	for i in 0 ..< LIGHT_SAMPLES {
		if s.light.live[i] == 0 do continue

		lx := i32(i % LIGHT_W)
		ly := i32(i / LIGHT_W)
		testing.expectf(
			t,
			abs(lx - centre_x) <= LIGHT_ORB_REACH && abs(ly - centre_y) <= LIGHT_ORB_REACH,
			"sample %d,%d is lit and lies past the %d the reach allows",
			lx, ly, i32(LIGHT_ORB_REACH),
		)
	}
}

@(test)
test_the_crystals_he_drops_keep_the_place_lit_after_he_leaves :: proc(t: ^testing.T) {
	s: Sim
	if !testing.expect(t, sim_load(&s) == .None, "the world must load") do return
	defer sim_unload(&s)
	sim_play_begin(&s)

	for _ in 0 ..< 240 do sim_step_player(&s, {.Right, .Run}, false)

	if !testing.expect(t, s.light.count > 0, "walking must shake crystals out of the orb") do return

	c := s.light.crystals[0]
	x := i32(math.floor(c.x))
	y := i32(math.floor(c.y))

	terrain := Terrain{world = s.world, sandbox = &s.sandbox}
	s.player.x += 4 * LIGHT_ORB_REACH * LIGHT_CELL
	light_step(&s.light, terrain, s.player)

	behind := light_lux(&s.light, x, y)
	never := light_lux(&s.light, x, y + 4 * LIGHT_ORB_REACH * LIGHT_CELL)

	testing.expectf(
		t, light_response[behind] > 0,
		"the place the crystal fell must stay lit after he walks away, got %d", behind,
	)
	testing.expectf(
		t, never == 0,
		"a place he never walked must stay in the gloom, got %d", never,
	)
}

@(test)
test_the_trail_he_leaves_never_outshines_the_orb_he_carries :: proc(t: ^testing.T) {
	s: Sim
	if !testing.expect(t, sim_load(&s) == .None, "the world must load") do return
	defer sim_unload(&s)
	sim_play_begin(&s)

	for _ in 0 ..< 240 do sim_step_player(&s, {.Right, .Run}, false)

	brightest_trail := u8(0)
	for v in s.light.stat do brightest_trail = max(brightest_trail, v)

	brightest_orb := u8(0)
	for v in s.light.live do brightest_orb = max(brightest_orb, v)

	testing.expectf(
		t, brightest_trail <= LIGHT_CRYSTAL_POWER,
		"no crystal may burn past LIGHT_CRYSTAL_POWER, got %d", brightest_trail,
	)
	testing.expectf(
		t, brightest_orb > brightest_trail,
		"the orb must be the brightest thing in the world, got %d against a trail of %d",
		brightest_orb, brightest_trail,
	)
}

@(test)
test_leaving_the_square_forgets_the_light_the_way_the_sandbox_forgets_the_digging :: proc(t: ^testing.T) {
	s: Sim
	if !testing.expect(t, sim_load(&s) == .None, "the world must load") do return
	defer sim_unload(&s)
	sim_play_begin(&s)

	for _ in 0 ..< 240 do sim_step_player(&s, {.Right, .Run}, false)
	if !testing.expect(t, s.light.count > 0, "walking must shake crystals out of the orb") do return

	before := s.light.origin_x
	light_follow(&s.light, before + SANDBOX_PLAY_SIZE, s.light.origin_y)

	testing.expect(t, s.light.origin_x == before + SANDBOX_PLAY_SIZE, "the grid must move with him")
	testing.expect(t, s.light.count == 0, "the crystals of the square he left must be forgotten")

	for v in s.light.stat {
		if !testing.expect(t, v == 0, "the light of the square he left must be forgotten with them") do return
	}
}

@(test)
test_the_orb_finds_open_air_when_the_staff_head_is_buried :: proc(t: ^testing.T) {
	s: Sim
	if !testing.expect(t, sim_load(&s) == .None, "the world must load") do return
	defer sim_unload(&s)

	rock, found := sim_material_index(&s, "Rock")
	if !testing.expect(t, found, "Rock must exist") do return

	sim_open_sandbox(&s, 512, 512, 0, 0, 1, 0)
	light_fill_box(&s.sandbox, 0, 0, 511, 511, Cell(rock))
	light_fill_box(&s.sandbox, 240, 250, 280, 263, MATERIAL_AIR)

	terrain := Terrain{world = s.world, sandbox = &s.sandbox}
	p := light_test_player(256, 263, 1)

	ox, oy := light_orb_at(p)
	testing.expectf(
		t, player_solid_at(terrain, i32(math.floor(ox)), i32(math.floor(oy))),
		"this test means nothing unless the staff head is inside the rock, and it is at %v,%v", ox, oy,
	)

	x, y := light_orb_source(terrain, p)
	testing.expectf(
		t, !player_solid_at(terrain, x, y),
		"a buried orb must throw its light from the open air it can reach, got %d,%d", x, y,
	)
}
