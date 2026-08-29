package game

import "core:fmt"
import "core:strings"
import "core:testing"
import "core:time"

// What a tick and a frame spend, phase by phase. The clock starts at
// prof_begin and lands in the phase at prof_end, so a phase holds the
// whole of what ran between the two, nested work included. Reading it
// is free of tooling: the game prints it (F3), bench prints it, and a
// headless shot prints it with profile=1.
//
// The phases are the outer loops of the game, not its inner cells: a
// timer inside a per-cell loop would cost more than the loop.

Prof_Phase :: enum u8 {
	// One simulation tick, sandbox_step and the steps beside it.
	Step_Wake, // swap the dirty rects, clear the moved flags
	Step_Rows, // the falling, spreading, burning, reacting rows
	Step_Age,  // age the bangs and the sparks
	Player,    // player_step: input, walking, digging
	Fireflies, // firefly_step
	Pots,      // pot_step, his and the drudges'
	Drudges,   // drudge_step
	Light,     // light_step: the floods and the boxes they clear

	// One drawn frame, app_regenerate and the draws after it.
	Generate,     // the authored world into the view cells
	Sandbox_Copy, // the sandbox over the view cells
	Shade,        // light_lux and light_shade over every pixel
	Upload,       // the pixels onto the GPU texture
	Water_Mark,   // find the water surface for the shader
	Shader_Mark,  // find each material's cells for its shader
	Draw,         // the raylib draws, EndDrawing and the swap
}

// The counts under the phases: how much matter a tick actually worked.
// An increment costs nothing worth measuring, so they stay on always,
// and the report turns them into "per tick" numbers beside the times.
Prof_Count :: enum u8 {
	Rows_Stepped, // sandbox_step_row calls
	Cells_Loaded, // cells the row loads brought in
	Hot_Rows,     // rows that held work: lifetime, fire or reactions
	Reacts,       // sandbox_react calls
	Fires,        // sandbox_spread_fire calls
	Moving_Rows,  // rows where the intent found something to move
	Swaps,        // swaps that landed
}

Prof :: struct {
	spent: [Prof_Phase]time.Duration,
	calls: [Prof_Phase]int,
	count: [Prof_Count]int,
	ticks: int,
	frames: int,
}

prof: Prof

prof_begin :: #force_inline proc() -> time.Tick {
	return time.tick_now()
}

prof_end :: #force_inline proc(phase: Prof_Phase, start: time.Tick) {
	prof.spent[phase] += time.tick_since(start)
	prof.calls[phase] += 1
}

prof_reset :: proc() {
	prof = {}
}

// The report divides tick phases by ticks and frame phases by frames,
// so every line reads as "what one of them costs".
prof_over :: proc(phase: Prof_Phase) -> int {
	tick_phases :: bit_set[Prof_Phase]{
		.Step_Wake, .Step_Rows, .Step_Age,
		.Player, .Fireflies, .Pots, .Drudges, .Light,
	}
	return phase in tick_phases ? prof.ticks : prof.frames
}

prof_line :: proc(b: ^strings.Builder, phase: Prof_Phase) {
	over := prof_over(phase)
	if over == 0 || prof.calls[phase] == 0 do return

	ms := time.duration_milliseconds(prof.spent[phase])
	fmt.sbprintfln(b, "%-12s %.3f ms  over %d", phase, ms / f64(over), over)
}

prof_report :: proc(allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	for phase in Prof_Phase {
		prof_line(&b, phase)
	}
	if prof.ticks > 0 {
		for c in Prof_Count {
			if prof.count[c] == 0 do continue
			fmt.sbprintfln(&b, "%-12s %d a tick", c, prof.count[c] / prof.ticks)
		}
	}
	return strings.to_string(b)
}

@(test)
test_the_profiler_reports_what_it_measured_and_nothing_else :: proc(t: ^testing.T) {
	keep := prof
	defer prof = keep

	prof_reset()
	prof.ticks = 2
	prof.frames = 1

	start := prof_begin()
	prof_end(.Step_Rows, start)
	prof_end(.Shade, prof_begin())

	report := prof_report(context.temp_allocator)
	testing.expect(t, strings.contains(report, "Step_Rows"), "a measured tick phase must appear")
	testing.expect(t, strings.contains(report, "over 2"), "a tick phase reads per tick")
	testing.expect(t, strings.contains(report, "Shade"), "a measured frame phase must appear")
	testing.expect(t, !strings.contains(report, "Player"), "a phase never entered must not appear")

	prof_reset()
	testing.expect(t, prof_report(context.temp_allocator) == "", "a reset profiler has nothing to say")
}
