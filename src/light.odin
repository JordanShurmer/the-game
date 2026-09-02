package game

import "core:math"
import "core:mem"
import testing "check"
import rl "vendor:raylib"

LIGHT_CELL :: 4
// The light is thrown into a square this many cells on a side, snapped
// to a grid of that size, and moves with the wizard square by square.
// It was the play sandbox's square once; the sandbox is the whole world
// now and the light keeps the square. See docs/lighting.md.
LIGHT_SQUARE :: 2048
LIGHT_W :: LIGHT_SQUARE / LIGHT_CELL
LIGHT_H :: LIGHT_SQUARE / LIGHT_CELL
LIGHT_SAMPLES :: LIGHT_W * LIGHT_H
LIGHT_QUEUE :: 1 << 16

LIGHT_FAINT :: 2
LIGHT_RESPONSE_GAMMA :: 0.65

LIGHT_ORB_DX :: 6.0
LIGHT_ORB_DY :: -19.0
LIGHT_ORB_MIRROR :: -0.5
LIGHT_ORB_SEEK :: 8

LIGHT_ORB_REACH :: 27
LIGHT_CRYSTAL_REACH :: 31

// What the day loses once it has to turn a corner. Straight down it
// loses nothing at all -- `light_throw_sky` walks the columns rather
// than flooding them -- so this is only what reaches under an overhang,
// down a bank and into the mouth of a cave. It dies fast in rock, which
// is what keeps a cave dark under a lit field.
LIGHT_DAY_FALL :: Light_Fall{open = 236, open_diag = 228, dense = 92, dense_diag = 62}

// How much day has to be falling on the orb before it goes out. He does
// not carry a lit lamp across a field at noon.
LIGHT_ORB_WAKES :: 110

// Every light in the world is a material, and how bright it burns is the
// luminosity of that material. The order they burn in is a rule, held by
// test_the_lights_of_the_world_are_ordered rather than by an #assert,
// because the numbers are in data/materials.txt and not here.
// See docs/lighting.md, "Every light is a material".
light_lumens :: #force_inline proc(table: Material_Table, material: u16) -> u8 {
	return table.materials[material].luminosity
}

Light_Fall :: struct {
	open:       u8,
	open_diag:  u8,
	dense:      u8,
	dense_diag: u8,
}

LIGHT_ORB_FALL :: Light_Fall{open = 212, open_diag = 196, dense = 108, dense_diag = 75}

// A crystal's light falls off more gently than the orb's own, and it
// burns low, so a tiny gem soaks a wide patch of ground in faint light
// without filling the cave with glow: the trail says "explored", it
// does not stage the scene. The reach grows with the falloff:
// test_every_reach_outlasts_the_falloff_it_bounds holds the two
// together.
// The diagonal keeps pace with the straight fall (234^sqrt2 in the
// 256ths), because at a falloff this gentle a lossier diagonal draws
// the pool as a four-pointed star instead of a pool.
LIGHT_CRYSTAL_FALL :: Light_Fall{open = 234, open_diag = 225, dense = 108, dense_diag = 75}

LIGHT_CRYSTALS :: 1024

// How near a crystal may fall to one already hanging: half the 320
// cell view the game opens on, so the trail stays a scatter of small
// far lights whichever way the path bends.
//
// This is the whole rule now. A crystal once had to fall into the
// dark as well, read off the stat grid, but the trail was retuned --
// luminosity 110, reach 31, a steeper falloff -- until a crystal's
// own light dies about 116 cells out, well inside this floor. The
// darkness test could no longer turn anything away that the floor did
// not, so it is gone. Soften LIGHT_CRYSTAL_FALL or lower this floor
// and something like it has to come back: even at the brightest a
// material row can carry, a crystal reaches only about 150 cells.
LIGHT_DROP_APART :: 160.0

LIGHT_GLOOM_R :: 30
LIGHT_GLOOM_G :: 30
LIGHT_GLOOM_B :: 42
LIGHT_GLOOM_LIFT_R :: 3
LIGHT_GLOOM_LIFT_G :: 3
LIGHT_GLOOM_LIFT_B :: 6

// The haze is the light a space is full of, and it takes the colour of
// whatever is doing the lighting. A flame fills a cave with warm air;
// the sky fills a field with cold air. One haze for both turned a lit
// sky the colour of smoke.
LIGHT_HAZE_R :: 78
LIGHT_HAZE_G :: 64
LIGHT_HAZE_B :: 38

LIGHT_DAY_HAZE_R :: 108
LIGHT_DAY_HAZE_G :: 146
LIGHT_DAY_HAZE_B :: 205

LIGHT_BLOOM_KNEE :: 96
LIGHT_BLOOM_STRENGTH :: 150
LIGHT_BLOOM :: rl.Color{255, 240, 206, 255}

LIGHT_ORB_HALO :: 10
LIGHT_ORB_BLAZE :: 3
LIGHT_ORB_PEAK :: 0.92

// The halo around the gem is small and faint: the rupee is the thing
// you see, and the flood on the ground is the light it gives. A blaze
// below zero is how a light says it has no bright heart to draw --
// both draw paths keep that rule.
LIGHT_CRYSTAL_HALO :: 8
LIGHT_CRYSTAL_BLAZE :: -1
LIGHT_CRYSTAL_PEAK :: 0.16

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
	day:      []u8,
	flood:    []i32,
	crystals: []Crystal,

	origin_x: i32,
	origin_y: i32,

	live_x:  i32,
	live_y:  i32,
	live_on: bool,

	count: i32,
	next:  i32,

	// Ticks since the day was last thrown, and whether the orb is
	// burning. He puts it out in the light and lights it in the dark,
	// so the draw path has to be told which.
	sky_age: i32,
	orb_lit: bool,

	seed: u64,
}

light_make :: proc(seed: u64) -> Light {
	return Light {
		stat = make([]u8, LIGHT_SAMPLES),
		live = make([]u8, LIGHT_SAMPLES),
		day = make([]u8, LIGHT_SAMPLES),
		flood = make([]i32, LIGHT_QUEUE),
		crystals = make([]Crystal, LIGHT_CRYSTALS),
		seed = seed,
	}
}

light_destroy :: proc(l: ^Light) {
	delete(l.stat)
	delete(l.live)
	delete(l.day)
	delete(l.flood)
	delete(l.crystals)
	l^ = {}
}

light_move :: proc(l: ^Light, t: Terrain, origin_x, origin_y: i32) {
	if l.stat == nil do return
	l.origin_x = origin_x
	l.origin_y = origin_y
	mem.zero_slice(l.stat)
	mem.zero_slice(l.live)
	l.live_on = false
	l.count = 0
	l.next = 0

	// The day is static light, like a crystal, so it is thrown once
	// with the square rather than sixty times a second.
	light_throw_sky(l, t)
	l.sky_age = 0
}

light_follow :: proc(l: ^Light, t: Terrain, x, y: i32) {
	if l.stat == nil do return
	origin_x := floor_div(x, LIGHT_SQUARE) * LIGHT_SQUARE
	origin_y := floor_div(y, LIGHT_SQUARE) * LIGHT_SQUARE
	if l.origin_x == origin_x && l.origin_y == origin_y do return
	light_move(l, t, origin_x, origin_y)
}

// The day is thrown with the square, but a wizard digs, and a hole he
// opens to the sky must let the day in. Re-throwing it every tick would
// cost a flood over the whole square sixty times a second, so it is
// re-thrown on a stride: often enough that a hole lights up while he is
// still standing in it, rarely enough to be free.
LIGHT_SKY_STRIDE :: 20

light_sky_age :: proc(l: ^Light, t: Terrain) {
	if l.stat == nil do return
	l.sky_age += 1
	if l.sky_age < LIGHT_SKY_STRIDE do return
	l.sky_age = 0
	light_throw_sky(l, t)
}

// How much day falls on a world cell. This is the whole of what says
// whether the wizard is out in the open or under the ground, and the
// orb reads it to know whether to burn.
light_day_at :: proc(l: ^Light, wx, wy: i32) -> u8 {
	if l.day == nil do return 0
	lx := light_slot(wx - l.origin_x)
	ly := light_slot(wy - l.origin_y)
	if lx < 0 || ly < 0 || lx >= LIGHT_W || ly >= LIGHT_H do return 0
	return l.day[int(ly) * LIGHT_W + int(lx)]
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

// The day.
//
// A biome may be a light (`light = Daylight` on [Sky] in
// data/biomes.txt), and the day is not thrown from a point the way a
// lamp is. Sunlight falls straight down and does not dim on the way:
// what it costs is what it passes *through*, and open air costs it
// nothing. So each column of the grid is walked from the top down,
// holding full power the whole way while the air is open, and stops at
// the first solid sample -- which takes the light, because that is the
// ground the sun lands on. Nothing below it is under the sky.
//
// Only then is it flooded, from the samples on that boundary, so the
// day still turns into an overhang, down a bank and a little way into
// the mouth of a cave, and dies fast in rock.
//
// Flooding it instead of dropping it -- which is what the first draft
// did, seeding the whole Sky *biome* and letting it fall -- put a
// hundred and sixty cells of open air between the sky and the fields,
// and two per cent lost a sample over forty samples is what turned noon
// into dusk.
//
// It gets a grid of its own rather than sharing `stat` with the
// crystals, because the orb reads the day to know whether to burn: with
// the two mixed, a trail of crystals would read as daylight and put out
// the very lamp that dropped them.
light_throw_sky :: proc(l: ^Light, t: Terrain) {
	if l.day == nil do return
	mem.zero_slice(l.day)

	// How far down each column the sky reaches, and the light it
	// carries there.
	//
	// The grid is walked a row at a time rather than a column at a
	// time, carrying a flag for each column saying whether the sky has
	// reached it yet. It is the same walk either way and gives the same
	// answer, but a column is a stride of two thousand cells through
	// the sandbox and every step of it misses the cache, where the
	// cells of a row are neighbours. Two hundred and eighteen thousand
	// of these are asked to throw the day over a surface square: 1.94
	// ms down the columns, 1.23 ms across the rows.
	depth: [LIGHT_W]i32
	power: [LIGHT_W]u8
	open: [LIGHT_W]bool

	lit := false
	for lx in i32(0) ..< LIGHT_W {
		depth[lx] = -1
		power[lx] = light_sky_at(l, t, lx)
		open[lx] = power[lx] > 0
		if open[lx] do lit = true
	}
	if !lit do return

	for ly in i32(0) ..< LIGHT_H {
		row := int(ly) * LIGHT_W
		reaching := false
		for lx in i32(0) ..< LIGHT_W {
			if !open[lx] do continue
			l.day[row + int(lx)] = power[lx]
			depth[lx] = ly
			if light_dense_at(l, t, lx, ly) {
				open[lx] = false
			} else {
				reaching = true
			}
		}
		// Every column has met its ground; there is no more sky to fall.
		if !reaching do break
	}

	// The frontier: the sample the sky stops at in each column, and
	// wherever a column reaches lower than the one beside it. Every
	// other lit sample has nothing but full daylight around it and
	// nowhere to spread to, so pushing it would only be work.
	tail := 0
	for lx in i32(0) ..< LIGHT_W {
		if depth[lx] < 0 do continue

		shallowest := depth[lx]
		if lx > 0 do shallowest = min(shallowest, depth[lx - 1] < 0 ? 0 : depth[lx - 1])
		if lx < LIGHT_W - 1 do shallowest = min(shallowest, depth[lx + 1] < 0 ? 0 : depth[lx + 1])

		for ly in max(shallowest - 1, 0) ..= depth[lx] {
			if tail >= len(l.flood) do break
			l.flood[tail] = i32(int(ly) * LIGHT_W + int(lx))
			tail += 1
		}
	}

	light_spread(l, l.day, t, tail, 0, 0, LIGHT_W - 1, LIGHT_H - 1, LIGHT_DAY_FALL)
}

// What the sky over one column throws, read at the top of the square.
// Zero says this column has no sky over it at all, which is the whole
// of why a light square deep in the coal costs nothing: every column
// answers zero and there is nothing to walk.
@(private = "file")
light_sky_at :: proc(l: ^Light, t: Terrain, lx: i32) -> u8 {
	wx := l.origin_x + lx * LIGHT_CELL + LIGHT_CELL / 2
	wy := l.origin_y + LIGHT_CELL / 2
	b := t.world.biomes.biomes[world_biome_at(t.world^, wx, wy)]
	if b.light == 0 do return 0
	return light_lumens(t.world.materials, b.light)
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
	light_spread(l, grid, t, 1, x0, y0, x1, y1, fall, start)
}

// The spread every light in the world shares: a queue of samples that
// are already lit, each pushing what is left of itself into the eight
// around it, dimmer for a step through anything solid than for a step
// through air. A lamp seeds it with one sample and the day seeds it
// with the line where the sky meets the ground; past that they are the
// same walk, so there is one answer to how light turns a corner and
// not two that can drift apart.
//
// `source` is the one sample allowed to spread as though it stood in
// open air whatever it stands in, so a lamp buried a cell deep still
// lights the hole it is in. The day has no such sample and passes -1.
light_spread :: proc(
	l: ^Light,
	grid: []u8,
	t: Terrain,
	tail_in: int,
	x0, y0, x1, y1: i32,
	fall: Light_Fall,
	source := -1,
) {
	head, tail := 0, tail_in

	for head < tail {
		at := int(l.flood[head])
		head += 1

		value := u32(grid[at])
		if value <= LIGHT_FAINT do continue

		ax := i32(at % LIGHT_W)
		ay := i32(at / LIGHT_W)
		dense := at != source && light_dense_at(l, t, ax, ay)

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
	return u32(max(l.stat[i], l.live[i], l.day[i]))
}

light_response: [256]u8

@(init)
light_response_init :: proc "contextless" () {
	for i in LIGHT_FAINT + 1 ..< 256 {
		light_response[i] = u8(255 * math.pow(f32(i - LIGHT_FAINT) / f32(255 - LIGHT_FAINT), LIGHT_RESPONSE_GAMMA))
	}
}

// What the moving lights throw this tick, with the static light -- the
// day and the crystals -- left out. A test about one lamp reads this,
// so the day standing over the whole square cannot answer for it.
light_live_lux :: proc(l: ^Light, wx, wy: i32) -> u8 {
	if l.live == nil do return 0
	lx := light_slot(wx - l.origin_x)
	ly := light_slot(wy - l.origin_y)
	if lx < 0 || ly < 0 || lx >= LIGHT_W || ly >= LIGHT_H do return 0
	return l.live[int(ly) * LIGHT_W + int(lx)]
}

// The day on a world cell, read the same interpolated way `light_lux`
// reads the light, so the haze does not step from warm to cold across
// the seam of a sample.
light_sky_lux :: proc(l: ^Light, wx, wy: i32) -> u8 {
	if l.day == nil do return 0

	fx := wx - l.origin_x - LIGHT_CELL / 2
	fy := wy - l.origin_y - LIGHT_CELL / 2
	lx := light_slot(fx)
	ly := light_slot(fy)
	tx := u32(fx - lx * LIGHT_CELL)
	ty := u32(fy - ly * LIGHT_CELL)

	corner :: #force_inline proc(l: ^Light, lx, ly: i32) -> u32 {
		if lx < 0 || ly < 0 || lx >= LIGHT_W || ly >= LIGHT_H do return 0
		return u32(l.day[int(ly) * LIGHT_W + int(lx)])
	}

	top := corner(l, lx, ly) * (LIGHT_CELL - tx) + corner(l, lx + 1, ly) * tx
	bottom := corner(l, lx, ly + 1) * (LIGHT_CELL - tx) + corner(l, lx + 1, ly + 1) * tx
	return u8((top * (LIGHT_CELL - ty) + bottom * ty) / (LIGHT_CELL * LIGHT_CELL))
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

// `sky` is how much of `lux` came from the day. It decides two things
// the light on a cell cannot say on its own:
//
//   - the colour of the haze, warm for a flame and cold for the sky, so
//     a lit field reads as open air and a lit cave as firelight;
//   - whether the cell blooms. A bloom is the blow-out of standing close
//     to a light, and the sky is not a thing you can stand close to, so
//     only the part of the light that is not the day may bloom. Without
//     that, every cell of a daylit field is bleached to the same warm
//     white and the picture goes flat.
light_shade :: proc(c: rl.Color, lux: u8, sky: u8 = 0) -> rl.Color {
	mix :: #force_inline proc(dark, lit, l: u32) -> u32 {
		return (dark * (255 - l) + lit * l) / 255
	}
	gloom :: #force_inline proc(v: u32, keep, lift: u32) -> u32 {
		return v * keep / 256 + lift
	}
	haze :: #force_inline proc(v: u32, l, fill: u32) -> u32 {
		return v + fill * l * (255 - v) / (255 * 255)
	}

	// The sky fills empty air with its own colour and leaves the ground
	// its own. A lamp's haze grows as a material darkens; the day's
	// grows as the *cube* of that, so air -- which has no colour at all
	// -- comes out sky blue, and anything that does have a colour keeps
	// it. Scaled the way a lamp's is, full daylight first bleached a
	// field to pale sand and then drowned it in blue.
	sky_haze :: #force_inline proc(v, l, fill: u32) -> u32 {
		// Cubed a step at a time. Written out as one product it is
		// fill*l*room^3, which is four hundred billion and does not fit
		// in a u32: it wrapped, and the sky came out black.
		room := 255 - v
		k := room * room / 255
		k = k * room / 255
		return v + fill * l * k / (255 * 255)
	}

	l := u32(light_response[lux])

	day := u32(min(sky, lux))
	share := lux == 0 ? u32(0) : day * 255 / u32(lux)
	lamp_l := l * (255 - share) / 255
	day_l := l * share / 255

	lift :: #force_inline proc(base, lamp_l, day_l, warm, cold: u32) -> u32 {
		return sky_haze(haze(base, lamp_l, warm), day_l, cold)
	}

	r := lift(mix(gloom(u32(c.r), LIGHT_GLOOM_R, LIGHT_GLOOM_LIFT_R), u32(c.r), l), lamp_l, day_l, LIGHT_HAZE_R, LIGHT_DAY_HAZE_R)
	g := lift(mix(gloom(u32(c.g), LIGHT_GLOOM_G, LIGHT_GLOOM_LIFT_G), u32(c.g), l), lamp_l, day_l, LIGHT_HAZE_G, LIGHT_DAY_HAZE_G)
	b := lift(mix(gloom(u32(c.b), LIGHT_GLOOM_B, LIGHT_GLOOM_LIFT_B), u32(c.b), l), lamp_l, day_l, LIGHT_HAZE_B, LIGHT_DAY_HAZE_B)

	lamp := lux - u8(day)
	if lamp > LIGHT_BLOOM_KNEE {
		over := u32(lamp - LIGHT_BLOOM_KNEE) * LIGHT_BLOOM_STRENGTH / (255 - LIGHT_BLOOM_KNEE)
		r = mix(r, u32(LIGHT_BLOOM.r), over)
		g = mix(g, u32(LIGHT_BLOOM.g), over)
		b = mix(b, u32(LIGHT_BLOOM.b), over)
	}

	return rl.Color{u8(min(r, 255)), u8(min(g, 255)), u8(min(b, 255)), 255}
}

light_step :: proc(l: ^Light, t: Terrain, p: Player, flies: ^Firefly_Swarm = nil, pots: ^Pot_Bag = nil, enemy_pots: ^Pot_Bag = nil, drudges: ^Drudge_Bag = nil) {
	if l.stat == nil do return
	light_sky_age(l, t)
	light_drop(l, t, p)
	light_throw(l, t, p, flies, pots, enemy_pots, drudges)
}

light_drop :: proc(l: ^Light, t: Terrain, p: Player) {
	x, y := light_orb_source(t, p)

	// Nothing falls from an orb that is not lit. The trail is the thing
	// he leaves in the dark to find his way back, so a walk across a
	// field in the day must not lay one.
	if light_day_at(l, x, y) >= LIGHT_ORB_WAKES do return

	// Nothing falls outside the light square: the orb hangs above him,
	// so he can stand in the top rows with the staff head over the
	// edge, and a crystal recorded out there would have no flood
	// behind it.
	lx := light_slot(x - l.origin_x)
	ly := light_slot(y - l.origin_y)
	if lx < 0 || ly < 0 || lx >= LIGHT_W || ly >= LIGHT_H do return

	// A crystal falls where the trail has run out, and nowhere else:
	// never beside one that already hangs, however dark the rock
	// between them keeps the place. The goal is exactly what it leaves
	// behind -- light where he has been -- so a walk back over his own
	// trail drops nothing.
	for i in 0 ..< int(l.count) {
		dx := f32(x) - l.crystals[i].x
		dy := f32(y) - l.crystals[i].y
		if dx * dx + dy * dy < LIGHT_DROP_APART * LIGHT_DROP_APART do return
	}

	l.crystals[l.next] = Crystal{x = f32(x), y = f32(y), twinkle = u8(wang_hash(l.seed, LIGHT_SALT_CRYSTAL, x, y))}
	l.next = (l.next + 1) % LIGHT_CRYSTALS
	l.count = min(l.count + 1, LIGHT_CRYSTALS)

	table := t.world.materials
	light_flood(l, l.stat, t, x, y, light_lumens(table, table.crystal), LIGHT_CRYSTAL_REACH, LIGHT_CRYSTAL_FALL)
}

light_throw :: proc(l: ^Light, t: Terrain, p: Player, flies: ^Firefly_Swarm = nil, pots: ^Pot_Bag = nil, enemy_pots: ^Pot_Bag = nil, drudges: ^Drudge_Bag = nil) {
	table := t.world.materials

	if l.live_on do light_clear_box(l.live, l.live_x, l.live_y, LIGHT_ORB_REACH)
	light_forget_flies(l, flies)
	light_forget_pots(l, pots)
	light_forget_pots(l, enemy_pots)
	light_forget_drudges(l, drudges)
	light_forget_bangs(l, t)
	light_forget_sparks(l, t)

	// The orb only burns in the dark. A wizard does not carry a lit
	// lamp across a field at noon, and a halo drawn over a daylit
	// village reads as a fault in the picture rather than as a light.
	x, y := light_orb_source(t, p)
	l.orb_lit = light_day_at(l, x, y) < LIGHT_ORB_WAKES

	if l.orb_lit {
		l.live_x = light_slot(x - l.origin_x)
		l.live_y = light_slot(y - l.origin_y)
		l.live_on = true
		light_flood(l, l.live, t, x, y, light_lumens(table, table.orb), LIGHT_ORB_REACH, LIGHT_ORB_FALL)
	} else {
		l.live_on = false
	}
	light_throw_flies(l, t, flies)
	light_throw_pots(l, t, pots)
	light_throw_pots(l, t, enemy_pots)
	light_throw_drudges(l, t, drudges, p)
	light_throw_bangs(l, t)
	light_throw_sparks(l, t)
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

		light_flood(l, l.live, t, x, y, firefly_power(t.world.materials, f^, flies.clock), FIREFLY_REACH, FIREFLY_FALL)
		f.lx = lx
		f.ly = ly
		f.lit = true
	}
}

// A drudge's lamp moves with him the way the orb moves with the wizard, so
// it is cleared and re-thrown every tick rather than flooded once. See
// docs/drudge.md, "Sight: seeing him before he sees you".
@(private = "file")
light_forget_drudges :: proc(l: ^Light, drudges: ^Drudge_Bag) {
	if drudges == nil do return

	for i in 0 ..< int(drudges.count) {
		d := &drudges.drudges[i]
		if !d.lamp_lit do continue
		light_clear_box(l.live, d.lx, d.ly, DRUDGE_LAMP_REACH)
		d.lamp_lit = false
	}
}

// The light leaves the lamp where the sheet draws it (`drudge_lamp_at`),
// not from his body's own centre, the same way the wizard's own light
// leaves the orb on his staff and not the middle of his robe. See
// docs/drudge.md, "Sight: seeing him before he sees you", and
// `test_the_drudge_lamp_light_starts_where_the_sheet_draws_the_lamp` below.
@(private = "file")
light_throw_drudges :: proc(l: ^Light, t: Terrain, drudges: ^Drudge_Bag, player: Player) {
	if drudges == nil do return

	table := t.world.materials
	for i in 0 ..< int(drudges.count) {
		d := &drudges.drudges[i]
		facing := drudge_facing(d^, player)
		fx, fy := drudge_lamp_at(d^, facing)
		x, y := i32(math.floor(fx)), i32(math.floor(fy))

		lx := light_slot(x - l.origin_x)
		ly := light_slot(y - l.origin_y)
		if lx < 0 || ly < 0 || lx >= LIGHT_W || ly >= LIGHT_H do continue

		light_flood(l, l.live, t, x, y, light_lumens(table, table.fire), DRUDGE_LAMP_REACH, DRUDGE_LAMP_FALL)
		d.lx = lx
		d.ly = ly
		d.lamp_lit = true
	}
}

@(private = "file")
light_forget_pots :: proc(l: ^Light, pots: ^Pot_Bag) {
	if pots == nil do return

	for i in 0 ..< int(pots.count) {
		p := &pots.pots[i]
		if !p.lit do continue
		light_clear_box(l.live, p.lx, p.ly, POT_FUSE_REACH)
		p.lit = false
	}
}

// A pot in flight carries its burning fuse, and a fuse is fire.
@(private = "file")
light_throw_pots :: proc(l: ^Light, t: Terrain, pots: ^Pot_Bag) {
	if pots == nil do return

	table := t.world.materials
	for i in 0 ..< int(pots.count) {
		p := &pots.pots[i]
		if !p.live do continue

		x := i32(math.floor(p.x))
		y := i32(math.floor(p.y))

		lx := light_slot(x - l.origin_x)
		ly := light_slot(y - l.origin_y)
		if lx < 0 || ly < 0 || lx >= LIGHT_W || ly >= LIGHT_H do continue

		light_flood(l, l.live, t, x, y, light_lumens(table, table.fire), POT_FUSE_REACH, POT_FUSE_FALL)
		p.lx = lx
		p.ly = ly
		p.lit = true
	}
}

@(private = "file")
light_bang_slot :: proc(l: ^Light, sb: ^Sandbox, b: Bang) -> (lx, ly: i32, on: bool) {
	lx = light_slot(sb.origin_x + b.x - l.origin_x)
	ly = light_slot(sb.origin_y + b.y - l.origin_y)
	return lx, ly, lx >= 0 && ly >= 0 && lx < LIGHT_W && ly < LIGHT_H
}

@(private = "file")
light_forget_bangs :: proc(l: ^Light, t: Terrain) {
	if t.sandbox == nil do return

	// A bang that has run out keeps its place for one more tick, which is
	// this one: the box it lit last tick is cleared here and never again.
	for b in t.sandbox.bangs.bangs {
		if b.life < 0 do continue
		lx, ly, on := light_bang_slot(l, t.sandbox, b)
		if !on do continue
		light_clear_box(l.live, lx, ly, BANG_REACH)
	}
}

// A bang is the brightest thing in the world while it lasts. It is one flood
// at the heart of the crater, and it stands for every cell of the blast
// material the crater holds, because they are all the same material and the
// crater is smaller than the reach. See docs/lighting.md, "The bangs".
@(private = "file")
light_throw_bangs :: proc(l: ^Light, t: Terrain) {
	if t.sandbox == nil do return

	table := t.world.materials
	for b in t.sandbox.bangs.bangs {
		if b.life <= 0 do continue
		if _, _, on := light_bang_slot(l, t.sandbox, b); !on do continue

		light_flood(
			l, l.live, t,
			t.sandbox.origin_x + b.x, t.sandbox.origin_y + b.y,
			bang_power(table, b), BANG_REACH, BANG_FALL,
		)
	}
}

// A sparkle clears the box it lit last tick, the firefly way: a slot
// written over in the middle of its life would otherwise leave the light
// it threw stuck on the ground. See docs/alchemy.md, "The ring".
@(private = "file")
light_forget_sparks :: proc(l: ^Light, t: Terrain) {
	if t.sandbox == nil do return

	for &sp in t.sandbox.sparks.sparks {
		if !sp.lit do continue
		light_clear_box(l.live, sp.lx, sp.ly, SPARKLE_REACH)
		sp.lit = false
	}
}

@(private = "file")
light_throw_sparks :: proc(l: ^Light, t: Terrain) {
	if t.sandbox == nil do return

	table := t.world.materials
	sb := t.sandbox
	for &sp in sb.sparks.sparks {
		if sp.life <= 0 do continue

		x := sb.origin_x + sp.x
		y := sb.origin_y + sp.y
		lx := light_slot(x - l.origin_x)
		ly := light_slot(y - l.origin_y)
		if lx < 0 || ly < 0 || lx >= LIGHT_W || ly >= LIGHT_H do continue

		light_flood(l, l.live, t, x, y, spark_power(table, sp), SPARKLE_REACH, SPARKLE_FALL)
		sp.lx = lx
		sp.ly = ly
		sp.lit = true
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

// A crystal breathes rather than blinks: the swing is kept small so the
// trail reads as still light soaked into the rock, not a string of
// fairy lights.
light_crystal_glow :: proc(c: Crystal, clock: f64) -> f32 {
	phase := f32(clock) * LIGHT_TWINKLE_HZ + f32(c.twinkle) * (2 * math.PI / 256)
	return 0.86 + 0.14 * math.sin(phase)
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
	table, ok := load_materials("data/materials.txt")
	defer destroy_material_table(table)
	if !testing.expect(t, ok, "materials must load") do return

	Case :: struct {
		what:  string,
		power: u8,
		reach: i32,
		fall:  Light_Fall,
	}
	cases := []Case {
		{"the orb", light_lumens(table, table.orb), LIGHT_ORB_REACH, LIGHT_ORB_FALL},
		{"a crystal", light_lumens(table, table.crystal), LIGHT_CRYSTAL_REACH, LIGHT_CRYSTAL_FALL},
		{"a bang", light_lumens(table, table.blast), BANG_REACH, BANG_FALL},
		{"a fuse", light_lumens(table, table.fire), POT_FUSE_REACH, POT_FUSE_FALL},
		{"a firefly", light_lumens(table, table.firefly), FIREFLY_REACH, FIREFLY_FALL},
		{"a sparkle", light_lumens(table, table.sparkle), SPARKLE_REACH, SPARKLE_FALL},
	}

	for c in cases {
		burns := light_fall_reach(c.power, c.fall)
		testing.expectf(
			t, burns <= c.reach,
			"%s still burns %d samples out and its box stops at %d, which draws a square of light and not a pool",
			c.what, burns, c.reach,
		)
	}
}

// The order the lights of the world burn in. It was an #assert while the
// numbers were in the code; the numbers are in data/materials.txt now, so it
// is a test over the shipped table instead.
@(test)
test_the_lights_of_the_world_are_ordered :: proc(t: ^testing.T) {
	table, ok := load_materials("data/materials.txt")
	defer destroy_material_table(table)
	if !testing.expect(t, ok, "materials must load") do return

	bang := light_lumens(table, table.blast)
	orb := light_lumens(table, table.orb)
	crystal := light_lumens(table, table.crystal)
	firefly := light_lumens(table, table.firefly)
	fuse := light_lumens(table, table.fire)
	sparkle := light_lumens(table, table.sparkle)

	testing.expectf(
		t, bang >= orb,
		"a bang must be the brightest thing in the world while it lasts, got %d against an orb of %d",
		bang, orb,
	)
	testing.expectf(
		t, orb >= sparkle,
		"a sparkle must never outshine the orb he carries, got %d against %d",
		sparkle, orb,
	)
	testing.expectf(
		t, sparkle > crystal,
		"a sparkle must outshine the trail he leaves, got %d against %d",
		sparkle, crystal,
	)
	testing.expectf(
		t, crystal < orb,
		"the trail he leaves must never outshine the orb he carries, got %d against %d",
		crystal, orb,
	)
	testing.expectf(
		t, firefly < crystal,
		"a firefly must never outshine the trail he leaves, got %d against %d",
		firefly, crystal,
	)
	testing.expectf(
		t, fuse < orb,
		"the fuse on a thrown pot must not outshine the orb he carries, got %d against %d",
		fuse, orb,
	)
}

// The smallest light in the world: brightness is not reach.
@(test)
test_a_sparkle_is_the_smallest_light_in_the_world :: proc(t: ^testing.T) {
	others := []i32{LIGHT_ORB_REACH, LIGHT_CRYSTAL_REACH, BANG_REACH, POT_FUSE_REACH, FIREFLY_REACH}
	for reach in others {
		testing.expectf(
			t, SPARKLE_REACH < reach,
			"a sparkle must be the smallest light in the world, and its reach of %d is not under %d",
			SPARKLE_REACH, reach,
		)
	}
}

@(test)
test_a_bang_lights_the_cave_it_goes_off_in :: proc(t: ^testing.T) {
	s: Sim
	if !testing.expect(t, sim_load(&s) == .None, "the world must load") do return
	defer sim_unload(&s)

	sim_open_sandbox(&s, 512, 512, 0, 0, 1, 0)
	light_move(&s.light, Terrain{world = &s.world, sandbox = &s.sandbox}, 0, 0)
	light_fill_box(&s.sandbox, 0, 0, 511, 511, MATERIAL_AIR)

	table := s.world.materials
	terrain := Terrain{world = &s.world, sandbox = &s.sandbox}
	p := light_test_player(20, 20, 1)

	// Far enough from the wizard that nothing he carries reaches it.
	away := i32(400)
	light_step(&s.light, terrain, p)
	testing.expectf(
		t, light_lux(&s.light, away, away) == 0,
		"this test means nothing unless the place is dark first, and it holds %d",
		light_lux(&s.light, away, away),
	)

	sandbox_explode(&s.sandbox, table, away, away, 20, 60)
	light_step(&s.light, terrain, p)

	lit := light_lux(&s.light, away, away)
	testing.expectf(t, lit > 0, "a bang must light the cave it goes off in, and it holds %d", lit)

	for _ in 0 ..< int(table.materials[table.blast].lifetime) + 2 {
		sandbox_step(&s.sandbox, table)
		light_step(&s.light, terrain, p)
	}

	after := light_lux(&s.light, away, away)
	testing.expectf(
		t, after == 0,
		"a bang leaves no light behind it, the way a firefly does not, and it holds %d",
		after,
	)
}

// The colour a light is painted and the colour the material carries are two
// numbers in two files that must agree, the same way the orb and the sheet do.
@(test)
test_every_light_is_painted_the_colour_its_material_carries :: proc(t: ^testing.T) {
	table, ok := load_materials("data/materials.txt")
	defer destroy_material_table(table)
	if !testing.expect(t, ok, "materials must load") do return

	Case :: struct {
		name:     string,
		material: u16,
		paint:    rl.Color,
	}
	cases := []Case {
		{"the orb", table.orb, LIGHT_GLOW},
		{"a crystal", table.crystal, LIGHT_CORE},
		{"a firefly", table.firefly, FIREFLY_GLOW},
		{"a bang", table.blast, BANG_CORE},
		{"a sparkle", table.sparkle, SPARKLE_GLOW},
	}

	for c in cases {
		got := rl_from_argb(table.materials[c.material].color)
		testing.expectf(
			t, got == c.paint,
			"%s is drawn %v and the %s material is painted %v, and the two must agree",
			c.name, c.paint, table.names[c.material], got,
		)
	}
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
test_the_drudge_lamp_light_starts_where_the_sheet_draws_the_lamp :: proc(t: ^testing.T) {
	table, ok := load_materials("data/materials.txt")
	defer destroy_material_table(table)
	if !testing.expect(t, ok, "materials must load") do return

	sheet, result := load_drudge_sprite_sheet()
	if !testing.expectf(t, result.err == .None, "the shipped drudge sheet must load, got %v", result.err) do return
	defer destroy_sprite_sheet(sheet)

	lamp := drudge_lamp_glow(table)

	for facing in ([]i8{1, -1}) {
		d := Drudge{x = 100, y = 100, dir = facing, on_ground = true}
		lx, ly := drudge_lamp_at(d, facing)
		frame_x, frame_y := drudge_sprite_frame_origin(d)

		fx := i32(math.floor(lx)) - frame_x
		fy := i32(math.floor(ly)) - frame_y
		got := drudge_sprite_pixel(sheet, .Idle, 0, facing, fx, fy)

		glow := got.r == lamp.r && got.g == lamp.g && got.b == lamp.b
		core := got.r == LIGHT_CORE.r && got.g == LIGHT_CORE.g && got.b == LIGHT_CORE.b
		testing.expectf(
			t, glow || core,
			"facing %d puts the light at frame (%d,%d), where the sheet draws %v and not the lamp",
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
	light_move(&s.light, Terrain{world = &s.world, sandbox = &s.sandbox}, 0, 0)

	light_fill_box(&s.sandbox, 0, 0, 511, 511, Cell(rock))
	light_fill_box(&s.sandbox, 0, 248, 511, 263, MATERIAL_AIR)

	terrain := Terrain{world = &s.world, sandbox = &s.sandbox}
	light_flood(&s.light, s.light.live, terrain, 32, 256, light_lumens(s.world.materials, s.world.materials.orb), LIGHT_ORB_REACH, LIGHT_ORB_FALL)

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
	light_move(&s.light, Terrain{world = &s.world, sandbox = &s.sandbox}, 0, 0)
	light_fill_box(&s.sandbox, 0, 0, 511, 511, MATERIAL_AIR)

	terrain := Terrain{world = &s.world, sandbox = &s.sandbox}
	light_flood(&s.light, s.light.live, terrain, 1024, 1024, light_lumens(s.world.materials, s.world.materials.orb), LIGHT_ORB_REACH, LIGHT_ORB_FALL)

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
test_the_orb_is_out_in_the_field_and_lit_under_the_ground :: proc(t: ^testing.T) {
	s: Sim
	if !testing.expect(t, sim_load(&s) == .None, "the world must load") do return
	defer sim_unload(&s)
	sim_play_begin(&s)

	// Where he starts: a field, under an open sky.
	sim_step_player(&s, {}, false)
	ox, oy := light_orb_source(sim_terrain(&s), s.player)
	testing.expectf(
		t, light_day_at(&s.light, ox, oy) >= LIGHT_ORB_WAKES,
		"the day must be full on the village green, and it is %d",
		light_day_at(&s.light, ox, oy),
	)
	testing.expect(t, !s.light.orb_lit, "he does not carry a lit lamp across a field at noon")
	testing.expect(t, light_live_lux(&s.light, ox, oy) == 0, "and an orb that is out throws nothing")

	crystals := s.light.count
	for _ in 0 ..< 240 do sim_step_player(&s, {.Right, .Run}, false)
	testing.expectf(
		t, s.light.count == crystals,
		"nothing falls from an orb that is not lit, and %d crystals did",
		s.light.count - crystals,
	)

	// And under the coal, where the only light is the one he brought.
	if !testing.expect(t, sim_stand_in_the_dark(&s), "the coal under the village must be walkable") do return
	sim_step_player(&s, {}, false)
	ox, oy = light_orb_source(sim_terrain(&s), s.player)
	testing.expectf(
		t, light_day_at(&s.light, ox, oy) == 0,
		"no day may reach the coal, and %d of it does",
		light_day_at(&s.light, ox, oy),
	)
	testing.expect(t, s.light.orb_lit, "in the dark he lights it")
	testing.expect(t, light_live_lux(&s.light, ox, oy) > 0, "and a lit orb throws light")
}

@(test)
test_the_crystals_he_drops_keep_the_place_lit_after_he_leaves :: proc(t: ^testing.T) {
	s: Sim
	if !testing.expect(t, sim_load(&s) == .None, "the world must load") do return
	defer sim_unload(&s)
	sim_play_begin(&s)
	if !testing.expect(t, sim_stand_in_the_dark(&s), "the coal under the village must be walkable") do return

	for _ in 0 ..< 240 do sim_step_player(&s, {.Right, .Run}, false)

	if !testing.expect(t, s.light.count > 0, "walking must shake crystals out of the orb") do return

	c := s.light.crystals[0]
	x := i32(math.floor(c.x))
	y := i32(math.floor(c.y))

	terrain := Terrain{world = &s.world, sandbox = &s.sandbox}
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

// The drop rule is the stat grid, so the trail goes where the light is
// missing and only there: a march into the dark lays crystals, and the
// march back over the lit trail lays none.
@(test)
test_no_crystal_falls_where_the_trail_already_lights_the_place :: proc(t: ^testing.T) {
	s: Sim
	if !testing.expect(t, sim_load(&s) == .None, "the world must load") do return
	defer sim_unload(&s)

	sim_open_sandbox(&s, 512, 512, 0, 0, 1, 0)
	light_move(&s.light, Terrain{world = &s.world, sandbox = &s.sandbox}, 0, 0)
	light_fill_box(&s.sandbox, 0, 0, 511, 511, MATERIAL_AIR)

	terrain := Terrain{world = &s.world, sandbox = &s.sandbox}
	if !testing.expect(t, light_day_at(&s.light, 256, 256) == 0, "this test means nothing unless the square is dark") do return

	// March him along a line and back again, a cell a tick, the way a
	// walk moves the orb without asking the physics to carry him.
	march :: proc(s: ^Sim, terrain: Terrain, from, to: f32) {
		step := from < to ? f32(1) : f32(-1)
		p := light_test_player(from, 256, i8(step))
		for p.x != to {
			p.x += step
			light_step(&s.light, terrain, p)
		}
	}

	march(&s, terrain, 60, 460)
	out := s.light.count
	if !testing.expect(t, out >= 2, "a march into the dark must lay a trail of crystals") do return

	// Way apart: in the open, a gem falls only where the light of the
	// one before has all but run out, which is more than half of the
	// 320 cell view the game opens on.
	for i in 1 ..< int(out) {
		dx := s.light.crystals[i].x - s.light.crystals[i - 1].x
		testing.expectf(
			t, abs(dx) >= 120,
			"crystals %d and %d fell %v cells apart, and in the open they must hang far apart",
			i - 1, i, abs(dx),
		)
	}

	march(&s, terrain, 460, 60)
	back := s.light.count - out
	testing.expectf(
		t, back == 0,
		"the march back is over ground the trail lights, so nothing should fall, and %d crystals did",
		back,
	)
}

// Around a corner the pool of the last crystal dies with the corridor
// that carried it, so the trail must turn the corner with him: a new
// crystal falls in the side passage though the last one is near as the
// crow flies.
@(test)
test_the_trail_turns_a_corner_with_him :: proc(t: ^testing.T) {
	s: Sim
	if !testing.expect(t, sim_load(&s) == .None, "the world must load") do return
	defer sim_unload(&s)

	rock, found := sim_material_index(&s, "Rock")
	if !testing.expect(t, found, "Rock must exist") do return

	sim_open_sandbox(&s, 512, 512, 0, 0, 1, 0)
	light_move(&s.light, Terrain{world = &s.world, sandbox = &s.sandbox}, 0, 0)

	// An L of open air in solid rock: a corridor east, then a shaft down.
	light_fill_box(&s.sandbox, 0, 0, 511, 511, Cell(rock))
	light_fill_box(&s.sandbox, 8, 240, 299, 263, MATERIAL_AIR)
	light_fill_box(&s.sandbox, 276, 240, 299, 480, MATERIAL_AIR)

	terrain := Terrain{world = &s.world, sandbox = &s.sandbox}

	p := light_test_player(30, 262, 1)
	for p.x < 288 {
		p.x += 1
		light_step(&s.light, terrain, p)
	}
	corner := s.light.count
	if !testing.expect(t, corner >= 1, "the corridor must hold at least one crystal") do return

	for p.y < 460 {
		p.y += 1
		light_step(&s.light, terrain, p)
	}

	dropped := i32(-1)
	for i in 0 ..< int(s.light.count) {
		if s.light.crystals[i].y > 300 do dropped = i32(i)
	}
	testing.expect(
		t, dropped >= 0,
		"the shaft is dark past the corner, so the trail must lay a crystal down it",
	)
}

@(test)
test_the_trail_he_leaves_never_outshines_the_orb_he_carries :: proc(t: ^testing.T) {
	s: Sim
	if !testing.expect(t, sim_load(&s) == .None, "the world must load") do return
	defer sim_unload(&s)
	sim_play_begin(&s)
	if !testing.expect(t, sim_stand_in_the_dark(&s), "the coal under the village must be walkable") do return

	for _ in 0 ..< 240 do sim_step_player(&s, {.Right, .Run}, false)

	brightest_trail := u8(0)
	for v in s.light.stat do brightest_trail = max(brightest_trail, v)

	brightest_orb := u8(0)
	for v in s.light.live do brightest_orb = max(brightest_orb, v)

	crystal := light_lumens(s.world.materials, s.world.materials.crystal)
	testing.expectf(
		t, brightest_trail <= crystal,
		"no crystal may burn past the luminosity of Light_Crystal, got %d against %d",
		brightest_trail, crystal,
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
	if !testing.expect(t, sim_stand_in_the_dark(&s), "the coal under the village must be walkable") do return

	for _ in 0 ..< 240 do sim_step_player(&s, {.Right, .Run}, false)
	if !testing.expect(t, s.light.count > 0, "walking must shake crystals out of the orb") do return

	before := s.light.origin_x
	light_follow(&s.light, sim_terrain(&s), before + LIGHT_SQUARE, s.light.origin_y)

	testing.expect(t, s.light.origin_x == before + LIGHT_SQUARE, "the grid must move with him")
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

	terrain := Terrain{world = &s.world, sandbox = &s.sandbox}
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
