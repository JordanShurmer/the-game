package game

/*
The numbers the step compares.

The step never reads a Material. A Material is 32 bytes of authored
data, and a cell that wants to know whether it can fall needs three of
them. These tables hold the same knowledge in two narrow numbers a
material, so a row of cells becomes a row of u16 and a row of u16, and
the whole question "can this fall" becomes one integer comparison.

The tables are built once, in load_materials, and indexed by material
id like every other table beside it.
*/

/*
The weight of a cell: the one number every move compares.

Air weighs nothing, so anything sinks into it. A wall weighs
everything, so nothing sinks into it and nothing rises into it.
Between those two a cell carries its own density in 1/256ths, which
is what makes oil float on water and sand sink through both.

Three things are walls: a solid, the world beyond the edge of the
sandbox, and a cell that already moved this tick. The step needs no
test for any of them, because all three arrive as the same number.

cell_weight_of clamps, so no density can reach either end by accident.
*/
CELL_AIR  :: u16(0)
CELL_WALL :: u16(0xFFFF)

// Which of the four rules a cell moves by.
Cell_Kind :: enum u16 {
	Still,  // air, and every solid: it stays where it is
	Powder, // falls straight down, then down to one side
	Liquid, // falls, and spreads along the floor when it cannot
	Riser,  // gas and flame: climbs, then drifts to one side
}

/*
What a cell needs from the hot pass.

The hot pass is everything that is not a move, and almost no cell
needs any of it. A cell with an empty set here skips the whole pass on
one comparison.
*/
Cell_Work :: enum u8 {
	Reacts, // it has a row in the reaction table
	Burns,  // contact with it sets a neighbour alight
	Flame,  // it is a flame, so it holds still while fuel is beside it
}
Cell_Works :: distinct bit_set[Cell_Work; u8]

// The weight of one material. See CELL_AIR and CELL_WALL above.
cell_weight_of :: proc(m: Material, is_air: bool) -> u16 {
	if is_air do return CELL_AIR
	if m.state == .Solid do return CELL_WALL

	// Fixed point, and clamped off both ends: a fluid must never
	// weigh nothing, or air would sink into it, and it must never
	// weigh everything, or it would be a wall.
	q := i64(m.density * 256)
	return u16(clamp(q, 1, i64(CELL_WALL) - 1))
}

// Which rule one material moves by. See Cell_Kind above. Air and
// every solid fall through to Still, which is the rule that says a
// cell stays where it is.
cell_kind_of :: proc(m: Material, is_air: bool) -> Cell_Kind {
	if !is_air {
		#partial switch m.state {
		case .Powder:        return .Powder
		case .Liquid:        return .Liquid
		case .Gas, .Special: return .Riser
		}
	}
	return .Still
}

// What one material needs from the hot pass. See Cell_Work above.
cell_work_of :: proc(m: Material, reacts: bool) -> Cell_Works {
	work: Cell_Works
	if reacts             do work += {.Reacts}
	if .Burns in m.contact do work += {.Burns}
	if m.state == .Special do work += {.Flame}
	return work
}
