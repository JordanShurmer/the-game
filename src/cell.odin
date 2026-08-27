package game

CELL_AIR  :: u16(0)
CELL_WALL :: u16(0xFFFF)

Cell_Kind :: enum u16 {
	Still,
	Powder,
	Liquid,
	Riser,
}

Cell_Work :: enum u8 {
	Reacts,
	Burns,
	Flame,
}
Cell_Works :: distinct bit_set[Cell_Work; u8]

cell_weight_of :: proc(m: Material, is_air: bool) -> u16 {
	if is_air do return CELL_AIR
	// Brush stands where it is, the same as a solid does: nothing the
	// sandbox moves is heavy enough to push a hedge aside.
	if m.state == .Solid || m.state == .Brush do return CELL_WALL

	q := i64(m.density * 256)
	return u16(clamp(q, 1, i64(CELL_WALL) - 1))
}

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

cell_work_of :: proc(m: Material, reacts: bool) -> Cell_Works {
	work: Cell_Works
	if reacts             do work += {.Reacts}
	if .Burns in m.contact do work += {.Burns}
	if m.state == .Special do work += {.Flame}
	return work
}
