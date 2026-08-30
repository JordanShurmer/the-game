package game

import "base:runtime"
import "core:fmt"
import "core:slice"
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
//
// The phases of a tick. The rest are the phases of a drawn frame, and
// the two are divided by different totals.
TICK_PHASES :: bit_set[Prof_Phase]{
	.Step_Wake, .Step_Rows, .Step_Age,
	.Player, .Fireflies, .Pots, .Drudges, .Light,
}

// The reports read a Prof they are handed rather than the global, so
// two of them can be measured at once without meeting each other. The
// game and the tools hand over `prof`; a test hands over its own.
prof_over :: proc(p: Prof, phase: Prof_Phase) -> int {
	return phase in TICK_PHASES ? p.ticks : p.frames
}

prof_line :: proc(b: ^strings.Builder, p: Prof, phase: Prof_Phase) {
	over := prof_over(p, phase)
	if over == 0 || p.calls[phase] == 0 do return

	ms := time.duration_milliseconds(p.spent[phase])
	fmt.sbprintfln(b, "%-12s %.3f ms  over %d", phase, ms / f64(over), over)
}

// A count in one word, for the breakdown line. The enum name says
// what it counts and this says it short, because the breakdown wants
// to fit on a line.
prof_count_word :: proc(c: Prof_Count) -> string {
	switch c {
	case .Rows_Stepped: return "rows"
	case .Cells_Loaded: return "cells"
	case .Hot_Rows:     return "hot"
	case .Reacts:       return "reacts"
	case .Fires:        return "fires"
	case .Moving_Rows:  return "moving"
	case .Swaps:        return "swaps"
	}
	return "?"
}

// The tick on one line, and the frame on another: each phase that was
// measured, the widest first, with what it costs and what share of
// its group that is. Then the counts, in one more line.
//
// This is the breakdown a bench prints on a normal run. It is a
// result and not talk: the whole point of a bench is the shape of the
// time, and a single total says which runs differ without saying
// where. prof_report is the same numbers at full width, one phase to
// a line, for a reader who has found the phase and wants it exact.
//
// The phases in a group are measured side by side and never inside
// one another, so the shares are a true division of the group.
prof_brief :: proc(p: Prof, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)

	Share :: struct {
		phase: Prof_Phase,
		ms:    f64,
	}

	group :: proc(b: ^strings.Builder, p: Prof, label: string, phases: bit_set[Prof_Phase], allocator: runtime.Allocator) {
		measured := make([dynamic]Share, allocator)
		defer delete(measured)

		total := 0.0
		for phase in Prof_Phase {
			if phase not_in phases do continue
			over := prof_over(p, phase)
			if over == 0 || p.calls[phase] == 0 do continue
			ms := time.duration_milliseconds(p.spent[phase]) / f64(over)
			append(&measured, Share{phase = phase, ms = ms})
			total += ms
		}
		if len(measured) == 0 do return

		// Widest first: the phase to look at is the phase to read first.
		slice.sort_by(measured[:], proc(a, b: Share) -> bool { return a.ms > b.ms })

		fmt.sbprintf(b, "%-6s", label)
		for m in measured {
			share := total > 0 ? 100 * m.ms / total : 0
			fmt.sbprintf(b, "  %v %.3f ms %.0f%%", m.phase, m.ms, share)
		}
		fmt.sbprintln(b)
	}

	group(&b, p, "tick", TICK_PHASES, allocator)
	group(&b, p, "frame", ~TICK_PHASES, allocator)

	if p.ticks > 0 {
		wrote := false
		for c in Prof_Count {
			if p.count[c] == 0 do continue
			if !wrote {
				fmt.sbprintf(&b, "%-6s", "work")
				wrote = true
			}
			fmt.sbprintf(&b, "  %d %s", p.count[c] / p.ticks, prof_count_word(c))
		}
		if wrote {
			fmt.sbprintfln(&b, "  a tick")
		}
	}

	return strings.to_string(b)
}

prof_report :: proc(p: Prof, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	for phase in Prof_Phase {
		prof_line(&b, p, phase)
	}
	if p.ticks > 0 {
		for c in Prof_Count {
			if p.count[c] == 0 do continue
			fmt.sbprintfln(&b, "%-12s %d a tick", c, p.count[c] / p.ticks)
		}
	}
	return strings.to_string(b)
}

@(test)
test_the_profiler_reports_what_it_measured_and_nothing_else :: proc(t: ^testing.T) {
	p: Prof
	p.ticks = 2
	p.frames = 1

	p.spent[.Step_Rows] = 4 * time.Millisecond
	p.calls[.Step_Rows] = 1
	p.spent[.Shade] = 1 * time.Millisecond
	p.calls[.Shade] = 1

	report := prof_report(p, context.temp_allocator)
	testing.expect(t, strings.contains(report, "Step_Rows"), "a measured tick phase must appear")
	testing.expect(t, strings.contains(report, "over 2"), "a tick phase reads per tick")
	testing.expect(t, strings.contains(report, "Shade"), "a measured frame phase must appear")
	testing.expect(t, strings.contains(report, "over 1"), "a frame phase reads per frame")
	testing.expect(t, !strings.contains(report, "Player"), "a phase never entered must not appear")

	testing.expect(
		t, prof_report(Prof{}, context.temp_allocator) == "",
		"a profiler that measured nothing has nothing to say",
	)
}

@(test)
test_the_clock_lands_in_the_phase_it_was_started_for :: proc(t: ^testing.T) {
	// prof_begin and prof_end write the one global the game measures
	// into, so this is the only test that touches it, and it puts back
	// what it found.
	keep := prof
	defer prof = keep

	prof_reset()
	prof_end(.Step_Rows, prof_begin())

	testing.expect(t, prof.calls[.Step_Rows] == 1, "the phase must count the call")
	testing.expect(t, prof.spent[.Step_Rows] >= 0, "and hold what it spent")
	testing.expect(t, prof.calls[.Light] == 0, "and no other phase must move")

	prof_reset()
	testing.expect(t, prof.calls[.Step_Rows] == 0, "a reset clears what was measured")
}

@(test)
test_the_breakdown_puts_the_widest_phase_first_and_divides_the_group :: proc(t: ^testing.T) {
	p: Prof
	p.ticks = 1
	p.frames = 1

	// Three tick phases with times a reader can check by eye: Light is
	// the widest, and the three are the whole of the group.
	p.spent[.Step_Wake] = 1 * time.Millisecond
	p.calls[.Step_Wake] = 1
	p.spent[.Light] = 7 * time.Millisecond
	p.calls[.Light] = 1
	p.spent[.Player] = 2 * time.Millisecond
	p.calls[.Player] = 1
	p.count[.Reacts] = 40

	brief := prof_brief(p, context.temp_allocator)

	testing.expectf(
		t, strings.index(brief, "Light") < strings.index(brief, "Player"),
		"the widest phase must come first, got %q", brief,
	)
	testing.expectf(
		t, strings.index(brief, "Player") < strings.index(brief, "Step_Wake"),
		"and the rest must follow it in order, got %q", brief,
	)
	testing.expectf(
		t, strings.contains(brief, "70%"),
		"7 ms of 10 must read as 70%%, got %q", brief,
	)
	testing.expectf(
		t, strings.contains(brief, "40 reacts"),
		"the counts must ride under the times, got %q", brief,
	)
	testing.expectf(
		t, !strings.contains(brief, "frame"),
		"a run that drew no frame must not print a frame line, got %q", brief,
	)

	// A frame phase makes the second line appear, divided on its own.
	p.spent[.Shade] = 3 * time.Millisecond
	p.calls[.Shade] = 1
	brief = prof_brief(p, context.temp_allocator)
	testing.expectf(
		t, strings.contains(brief, "frame") && strings.contains(brief, "Shade"),
		"a measured frame phase must get its own line, got %q", brief,
	)
	testing.expectf(
		t, strings.contains(brief, "100%"),
		"the only frame phase must be all of its group, got %q", brief,
	)

	testing.expect(t, prof_brief(Prof{}, context.temp_allocator) == "", "a profiler that measured nothing has nothing to say")
}
