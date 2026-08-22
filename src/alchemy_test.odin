package game

// The second alchemy, measured in the sandbox it runs in.
//
// Thirteen materials and twenty two rows of data, and no code knows the name
// of one of them: every test here paints cells, steps the sandbox, and counts
// what is left. See docs/alchemy.md, "The second alchemy".

import "core:testing"

@(private = "file")
alchemy_sandbox :: proc(t: ^testing.T, width, height: i32, seed: u64) -> (Sandbox, Material_Table) {
	table, load_ok := load_materials("data/materials.txt")
	testing.expect(t, load_ok, "materials must load")

	sb, make_ok := sandbox_make(width, height, seed)
	testing.expect(t, make_ok, "the sandbox must be created")
	return sb, table
}

// Paint every cell of rows [y0,y1) with one material.
@(private = "file")
alchemy_band :: proc(sb: ^Sandbox, table: Material_Table, y0, y1: i32, material: int) {
	for y in y0 ..< y1 {
		for x in i32(0) ..< sb.width do sandbox_paint(sb, table, x, y, 0, Cell(material))
	}
}

// Bands of two materials, a cell at a time, so every cell of one touches a
// cell of the other and no cell is left stranded behind what the two make.
@(private = "file")
alchemy_interleave :: proc(sb: ^Sandbox, table: Material_Table, y0, y1: i32, a, b: int) {
	for y in y0 ..< y1 {
		alchemy_band(sb, table, y, y + 1, (y - y0) % 2 == 0 ? a : b)
	}
}

@(private = "file")
alchemy_live_sparks :: proc(sb: ^Sandbox) -> int {
	live := 0
	for sp in sb.sparks.sparks {
		if sp.life >= 0 do live += 1
	}
	return live
}

// ----------------------------------------------------------------- the salts

// Salt goes into water and heat brings it back out of it. The road runs both
// ways, which is the whole point of the salt rows.
@(test)
test_salt_goes_into_water_and_heat_brings_it_back :: proc(t: ^testing.T) {
	sb, table := alchemy_sandbox(t, 12, 40, 11)
	defer sandbox_destroy(&sb)
	defer destroy_material_table(table)

	sealt, _ := find_material_index(table, "Sealt")
	water, _ := find_material_index(table, "Water")
	brine, _ := find_material_index(table, "Brine")
	fire, _ := find_material_index(table, "Fire")
	rock, _ := find_material_index(table, "Rock")

	alchemy_band(&sb, table, 38, 40, rock)
	alchemy_interleave(&sb, table, 10, 38, sealt, water)

	counts := make([]int, len(table.materials))
	defer delete(counts)

	sandbox_census(&sb, counts)
	poured := counts[sealt]

	for _ in 0 ..< 600 do sandbox_step(&sb, table)
	sandbox_census(&sb, counts)

	testing.expectf(
		t, counts[brine] > poured,
		"salt poured into water must leave brine, and %d cells of salt left %d of brine",
		poured, counts[brine],
	)
	testing.expectf(
		t, counts[sealt] < poured / 2,
		"and most of the salt must go into it: %d of %d cells are left", counts[sealt], poured,
	)
	dissolved := counts[sealt]

	// The heat: fire banded into the brine, so nothing the drying leaves can
	// settle between the flame and what is left to dry.
	for y in i32(10) ..< 38 {
		if (y - 10) % 2 == 0 do continue
		for x in i32(0) ..< 12 do sandbox_paint(&sb, table, x, y, 0, Cell(fire))
	}
	for _ in 0 ..< 600 do sandbox_step(&sb, table)
	sandbox_census(&sb, counts)

	testing.expectf(
		t, counts[sealt] > dissolved,
		"heat over the brine must bring the salt back: %d cells against the %d that were left",
		counts[sealt], dissolved,
	)
}

// A pan of brine over lava dries at its surface, and the salt it leaves is
// lighter than lava and heavier than brine, so it settles exactly between the
// two and caps the pan. This is the trap docs/alchemy.md, "Layering seals a
// slow drip", describes, now in a powder: the pan goes still with brine still
// in it, and nothing will start it again.
@(test)
test_a_salt_pan_crusts_over_with_its_own_salt :: proc(t: ^testing.T) {
	sb, table := alchemy_sandbox(t, 10, 24, 5)
	defer sandbox_destroy(&sb)
	defer destroy_material_table(table)

	brine, _ := find_material_index(table, "Brine")
	lava, _ := find_material_index(table, "Lava")
	sealt, _ := find_material_index(table, "Sealt")

	alchemy_band(&sb, table, 20, 24, lava)
	alchemy_band(&sb, table, 8, 16, brine)

	counts := make([]int, len(table.materials))
	defer delete(counts)

	for _ in 0 ..< 1000 do sandbox_step(&sb, table)
	sandbox_census(&sb, counts)
	crusted_salt := counts[sealt]
	crusted_brine := counts[brine]

	testing.expect(t, crusted_salt > 0, "a pan of brine on lava must leave salt")
	testing.expect(t, crusted_brine > 0, "and cap itself before the pan is dry")

	for _ in 0 ..< 4000 do sandbox_step(&sb, table)
	sandbox_census(&sb, counts)

	testing.expectf(
		t, counts[sealt] == crusted_salt && counts[brine] == crusted_brine,
		"and then it is still for ever: salt %d against %d, brine %d against %d",
		counts[sealt], crusted_salt, counts[brine], crusted_brine,
	)
}

// ---------------------------------------------------------- the black powder

// Black powder is made of three things and a reaction takes two cells, so it
// is made in two steps: nitre and brimstone make the black salt, and the
// black salt takes up coal. See docs/alchemy.md, "Black powder, in two steps".
@(test)
test_black_powder_is_made_in_two_steps :: proc(t: ^testing.T) {
	sb, table := alchemy_sandbox(t, 16, 30, 3)
	defer sandbox_destroy(&sb)
	defer destroy_material_table(table)

	nitre, _ := find_material_index(table, "Nitre")
	brimstone, _ := find_material_index(table, "Brimstone")
	black, _ := find_material_index(table, "Sweartsealt")
	coal, _ := find_material_index(table, "Coal")
	powder, _ := find_material_index(table, "Gunpowder")

	alchemy_band(&sb, table, 26, 30, coal)
	alchemy_interleave(&sb, table, 0, 26, nitre, brimstone)

	counts := make([]int, len(table.materials))
	defer delete(counts)

	made_black := false
	made_powder := false
	for _ in 0 ..< 3000 {
		sandbox_step(&sb, table)
		sandbox_census(&sb, counts)
		if counts[black] > 0 do made_black = true
		if counts[powder] > 0 {
			made_powder = true
			break
		}
	}

	testing.expect(t, made_black, "nitre meeting brimstone must make the black salt")
	testing.expectf(
		t, made_powder,
		"and the black salt meeting coal must make black powder: black %d, powder %d",
		counts[black], counts[powder],
	)
}

// Brimstone does not catch as flame. It gives off its reek first, and the reek
// is what burns, so a bed of it lights by way of a fume that rises off it.
@(test)
test_brimstone_burns_by_way_of_its_reek :: proc(t: ^testing.T) {
	sb, table := alchemy_sandbox(t, 20, 12, 9)
	defer sandbox_destroy(&sb)
	defer destroy_material_table(table)

	brimstone, _ := find_material_index(table, "Brimstone")
	reek, _ := find_material_index(table, "Reek")
	rock, _ := find_material_index(table, "Rock")

	testing.expectf(
		t, int(table.burns_to[brimstone]) == reek,
		"brimstone must burn to its reek and not to a flame: it burns to %s",
		table.names[table.burns_to[brimstone]],
	)

	alchemy_band(&sb, table, 11, 12, rock)
	alchemy_band(&sb, table, 9, 11, brimstone)
	sandbox_ignite(&sb, table, 0, 9, 1)

	counts := make([]int, len(table.materials))
	defer delete(counts)

	reeked := false
	for _ in 0 ..< 1200 {
		sandbox_step(&sb, table)
		sandbox_census(&sb, counts)
		if counts[reek] > 0 {
			reeked = true
			break
		}
	}
	testing.expect(t, reeked, "brimstone reached by fire must give off its reek")
}

// ------------------------------------------------------------------ the lye

// Ash left standing in water is lye, and lye and acid put each other out and
// leave the calm liquid the first alchemy named.
@(test)
test_lye_and_acid_put_each_other_out :: proc(t: ^testing.T) {
	sb, table := alchemy_sandbox(t, 12, 30, 17)
	defer sandbox_destroy(&sb)
	defer destroy_material_table(table)

	ash, _ := find_material_index(table, "Ash")
	water, _ := find_material_index(table, "Water")
	leag, _ := find_material_index(table, "Leag")
	acid, _ := find_material_index(table, "Acid")
	smylt, _ := find_material_index(table, "Smylt")

	alchemy_band(&sb, table, 14, 30, water)
	alchemy_band(&sb, table, 0, 6, ash)

	counts := make([]int, len(table.materials))
	defer delete(counts)

	for _ in 0 ..< 1500 do sandbox_step(&sb, table)
	sandbox_census(&sb, counts)
	lye_before := counts[leag]
	if !testing.expect(t, lye_before > 0, "ash left standing in water must make lye") do return

	// Now pour acid onto the lye, and watch the two of them go.
	alchemy_band(&sb, table, 0, 6, acid)

	made_smylt := false
	for _ in 0 ..< 2000 {
		sandbox_step(&sb, table)
		sandbox_census(&sb, counts)
		if counts[smylt] > 0 {
			made_smylt = true
			break
		}
	}
	testing.expect(t, made_smylt, "lye meeting acid must leave the calm liquid")
	testing.expectf(
		t, counts[leag] < lye_before,
		"and both are spent doing it: %d of %d cells of lye are left", counts[leag], lye_before,
	)
	testing.expectf(t, counts[acid] < 12 * 6, "the acid too: %d cells are left", counts[acid])
}

// --------------------------------------------------------------- the metals

// Quicksilver takes gold up into an amalgam. Nothing else in the world can
// move gold at all: it is a solid, and a solid stays in the wall it is in.
@(test)
test_quicksilver_takes_up_gold :: proc(t: ^testing.T) {
	sb, table := alchemy_sandbox(t, 12, 20, 23)
	defer sandbox_destroy(&sb)
	defer destroy_material_table(table)

	quick, _ := find_material_index(table, "Cwicseolfor")
	gold, _ := find_material_index(table, "Gold")
	gemang, _ := find_material_index(table, "Gemang")

	alchemy_band(&sb, table, 12, 16, gold)
	alchemy_band(&sb, table, 8, 12, quick)

	counts := make([]int, len(table.materials))
	defer delete(counts)

	sandbox_census(&sb, counts)
	gold_before := counts[gold]

	made := false
	for _ in 0 ..< 600 {
		sandbox_step(&sb, table)
		sandbox_census(&sb, counts)
		if counts[gemang] > 0 {
			made = true
			break
		}
	}
	if !testing.expect(t, made, "quicksilver standing on gold must make an amalgam") do return
	testing.expectf(
		t, counts[gold] < gold_before,
		"and the gold must go into it: %d of %d cells are still gold", counts[gold], gold_before,
	)
	testing.expectf(
		t, counts[quick] > 0,
		"the quicksilver takes up only what it touches: none of it is left",
	)
}

// Fire drives the quicksilver off an amalgam and leaves the gold. The flame
// has to stand on the amalgam to do it, so the fire is fed by a film of oil:
// a flame in the air over it rises away before it can work.
@(test)
test_fire_drives_the_quicksilver_off_and_leaves_the_gold :: proc(t: ^testing.T) {
	sb, table := alchemy_sandbox(t, 16, 20, 47)
	defer sandbox_destroy(&sb)
	defer destroy_material_table(table)

	gemang, _ := find_material_index(table, "Gemang")
	gold, _ := find_material_index(table, "Gold")
	oil, _ := find_material_index(table, "Oil")

	alchemy_band(&sb, table, 14, 18, gemang)
	alchemy_band(&sb, table, 12, 14, oil)
	for x in i32(0) ..< 16 do sandbox_ignite(&sb, table, x, 13, 1)

	counts := make([]int, len(table.materials))
	defer delete(counts)

	sandbox_census(&sb, counts)
	amalgam_before := counts[gemang]

	for _ in 0 ..< 600 do sandbox_step(&sb, table)
	sandbox_census(&sb, counts)

	testing.expectf(
		t, counts[gold] > 0,
		"a fire on an amalgam must leave gold behind, and %d cells of it left none", amalgam_before,
	)
	testing.expectf(
		t, counts[gemang] < amalgam_before,
		"and the amalgam it was made of must go: %d of %d cells are left",
		counts[gemang], amalgam_before,
	)
}

// --------------------------------------------------------------- the magics

// A spell is spent in the flash it makes: the cell that held the Galdor is the
// cell the Sparkle is written into, and the quicksilver beside it is gold.
@(test)
test_a_spell_turns_quicksilver_to_gold_in_a_flash :: proc(t: ^testing.T) {
	sb, table := alchemy_sandbox(t, 16, 20, 29)
	defer sandbox_destroy(&sb)
	defer destroy_material_table(table)

	galdor, _ := find_material_index(table, "Galdor")
	quick, _ := find_material_index(table, "Cwicseolfor")
	gold, _ := find_material_index(table, "Gold")

	// Galdor is lighter than water and quicksilver is the heaviest liquid
	// there is, so the spell floats on it and the two meet along one line.
	alchemy_band(&sb, table, 12, 18, quick)
	alchemy_band(&sb, table, 6, 12, galdor)
	spark_forget_all(&sb.sparks)

	counts := make([]int, len(table.materials))
	defer delete(counts)

	made_gold := false
	lit := false
	for _ in 0 ..< 900 {
		sandbox_step(&sb, table)
		sandbox_census(&sb, counts)
		if alchemy_live_sparks(&sb) > 0 do lit = true
		if counts[gold] > 0 do made_gold = true
	}
	testing.expect(t, made_gold, "a spell on quicksilver must make gold")
	testing.expect(t, lit, "and it must be spent as a flash the light ring can see")
	testing.expectf(
		t, counts[galdor] < 16 * 6,
		"the spell is used up doing it: %d cells are left", counts[galdor],
	)
}

// A gleam is not a light of its own. It answers water with one, a spark for
// every drop, and the crystal itself is never used up.
@(test)
test_a_gleam_answers_every_drop_with_a_spark :: proc(t: ^testing.T) {
	sb, table := alchemy_sandbox(t, 10, 16, 31)
	defer sandbox_destroy(&sb)
	defer destroy_material_table(table)

	leoma, _ := find_material_index(table, "Leoma")
	water, _ := find_material_index(table, "Water")

	alchemy_band(&sb, table, 12, 16, leoma)
	alchemy_band(&sb, table, 0, 4, water)
	spark_forget_all(&sb.sparks)

	counts := make([]int, len(table.materials))
	defer delete(counts)

	sandbox_census(&sb, counts)
	crystals := counts[leoma]
	water_start := counts[water]

	lit := false
	for _ in 0 ..< 600 {
		sandbox_step(&sb, table)
		if alchemy_live_sparks(&sb) > 0 do lit = true
	}
	sandbox_census(&sb, counts)

	testing.expect(t, lit, "water falling on a gleam must throw a spark")
	testing.expectf(
		t, counts[leoma] == crystals,
		"and the crystal must not be used up: %d of %d cells are left", counts[leoma], crystals,
	)
	testing.expectf(
		t, counts[water] < water_start,
		"the water is what is spent: %d of %d cells are left", counts[water], water_start,
	)
	testing.expectf(
		t, table.materials[leoma].luminosity == 0,
		"and a gleam carries no light of its own, only the spark it answers with, and it carries %d",
		table.materials[leoma].luminosity,
	)
}

// A magic only skins what it lies on. There is no row for a spell on a
// gleam, so the first shell of gleam a spell makes is a wall between the
// spell and the stone under it, and the pour stops with spell to spare.
@(test)
test_a_spell_skins_a_stone_and_goes_no_deeper :: proc(t: ^testing.T) {
	sb, table := alchemy_sandbox(t, 20, 24, 53)
	defer sandbox_destroy(&sb)
	defer destroy_material_table(table)

	galdor, _ := find_material_index(table, "Galdor")
	rock, _ := find_material_index(table, "Rock")
	leoma, _ := find_material_index(table, "Leoma")

	alchemy_band(&sb, table, 12, 24, rock)
	alchemy_band(&sb, table, 2, 10, galdor)

	counts := make([]int, len(table.materials))
	defer delete(counts)

	for _ in 0 ..< 1000 do sandbox_step(&sb, table)
	sandbox_census(&sb, counts)
	skin := counts[leoma]
	spell := counts[galdor]

	testing.expect(t, skin > 0, "a spell must turn the stone it lands on into a gleam")
	testing.expectf(
		t, skin < 20 * 12 / 2,
		"but not the whole block: %d of %d cells of rock are a gleam", skin, 20 * 12,
	)
	testing.expectf(t, spell > 0, "and the spell must be left over, not used up")

	for _ in 0 ..< 3000 do sandbox_step(&sb, table)
	sandbox_census(&sb, counts)

	testing.expectf(
		t, counts[leoma] == skin,
		"and the shell is where it stops: %d cells of gleam against %d, 3000 ticks later",
		counts[leoma], skin,
	)
	testing.expect(t, counts[rock] > 0, "the stone under the shell is untouched")
}

// The cure is the quiet opposite of the mix. Attor and water flash; Attor and
// the cure leave the same calm liquid and throw no light at all.
@(test)
test_the_cure_puts_the_poison_out_with_no_light :: proc(t: ^testing.T) {
	sb, table := alchemy_sandbox(t, 10, 40, 37)
	defer sandbox_destroy(&sb)
	defer destroy_material_table(table)

	haelu, _ := find_material_index(table, "Haelu")
	attor, _ := find_material_index(table, "Attor")
	smylt, _ := find_material_index(table, "Smylt")

	alchemy_interleave(&sb, table, 0, 40, haelu, attor)
	spark_forget_all(&sb.sparks)

	counts := make([]int, len(table.materials))
	defer delete(counts)

	lit := false
	for _ in 0 ..< 2000 {
		sandbox_step(&sb, table)
		if alchemy_live_sparks(&sb) > 0 do lit = true
	}
	sandbox_census(&sb, counts)

	testing.expect(t, counts[smylt] > 0, "the cure meeting the poison must leave the calm liquid")
	testing.expectf(
		t, counts[attor] == 0,
		"and it must put every cell of it out: %d cells of Attor are left", counts[attor],
	)
	testing.expect(t, !lit, "and it must throw no light doing it: the cure is not the mix")
}

// The shadow puts fires out, and it is not used up doing it.
@(test)
test_the_shadow_puts_a_fire_out :: proc(t: ^testing.T) {
	sb, table := alchemy_sandbox(t, 16, 20, 41)
	defer sandbox_destroy(&sb)
	defer destroy_material_table(table)

	sceadu, _ := find_material_index(table, "Sceadu")
	oil, _ := find_material_index(table, "Oil")
	fire, _ := find_material_index(table, "Fire")
	rock, _ := find_material_index(table, "Rock")

	// A floor of rock, a film of oil on it, and the shadow poured over the
	// oil: the fire has fuel under it, and it still goes out.
	alchemy_band(&sb, table, 19, 20, rock)
	alchemy_band(&sb, table, 17, 19, oil)
	alchemy_band(&sb, table, 8, 17, sceadu)

	counts := make([]int, len(table.materials))
	defer delete(counts)

	sandbox_census(&sb, counts)
	shadow_start := counts[sceadu]

	for x in i32(0) ..< 16 do sandbox_ignite(&sb, table, x, 17, 1)

	out := false
	for _ in 0 ..< 2000 {
		sandbox_step(&sb, table)
		sandbox_census(&sb, counts)
		if counts[fire] == 0 {
			out = true
			break
		}
	}
	testing.expect(t, out, "a fire under the shadow must go out")
	testing.expectf(
		t, counts[sceadu] >= shadow_start - shadow_start / 4,
		"and the shadow must not be spent doing it: %d of %d cells are left",
		counts[sceadu], shadow_start,
	)
}

// The two magics undo each other. A cure and a shadow that meet leave the calm
// liquid and neither one of them.
@(test)
test_the_cure_and_the_shadow_undo_each_other :: proc(t: ^testing.T) {
	sb, table := alchemy_sandbox(t, 10, 40, 43)
	defer sandbox_destroy(&sb)
	defer destroy_material_table(table)

	haelu, _ := find_material_index(table, "Haelu")
	sceadu, _ := find_material_index(table, "Sceadu")
	smylt, _ := find_material_index(table, "Smylt")

	alchemy_interleave(&sb, table, 0, 40, haelu, sceadu)

	counts := make([]int, len(table.materials))
	defer delete(counts)

	for _ in 0 ..< 2000 do sandbox_step(&sb, table)
	sandbox_census(&sb, counts)

	testing.expectf(
		t, counts[haelu] == 0 && counts[sceadu] == 0,
		"neither magic may be left: %d of the cure and %d of the shadow",
		counts[haelu], counts[sceadu],
	)
	testing.expect(t, counts[smylt] > 0, "and the calm liquid is what they leave")
}

// Thirteen new materials fit under the wide lookup with room to spare, so the
// vectorised pass docs/physics.md describes still runs on every biome. See
// docs/alchemy.md, "What it costs", for why this is a rule and not a note.
@(test)
test_the_second_alchemy_leaves_the_wide_pass_standing :: proc(t: ^testing.T) {
	table, ok := load_materials("data/materials.txt")
	defer destroy_material_table(table)
	if !testing.expect(t, ok, "materials must load") do return

	testing.expectf(
		t, len(table.materials) <= SANDBOX_WIDE_IDS,
		"the shipped table is %d materials and the wide pass covers %d",
		len(table.materials), SANDBOX_WIDE_IDS,
	)
	testing.expect(t, table.lut_ok, "the weight lookup must hold every material")
}
