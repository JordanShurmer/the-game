package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"

import game "../../src"

/*
Time one tick of the sandbox, on a real region of the shipped world.

docs/physics.md says to measure before writing, and this is what
measures. It opens a sandbox the size the game runs on a rectangle the
generator paints, runs it, and reports what a tick costs. No window,
and no display.

	make bench
	./bin/bench                              # Coalmine, 2048 square
	./bin/bench biome=Lake                   # the heaviest biome shipped
	./bin/bench biome=Lake size=512 ticks=50 # smaller, and quicker

Arguments are `key=value`: `biome size ticks warm`.

A biome is not a workload on its own. A tick costs what the cells in
it are doing, so a rectangle of rock and air costs almost nothing and
one of water costs the most. `size` changes which rectangle is opened
and not only how large it is, so a smaller run can be quieter than the
cells alone say. Read `biome` and `size` together as the name of one
workload, and compare a number only against the same name.

The checksum is printed with the time. The step is deterministic, so
two runs of the same arguments give the same checksum, and a change
that keeps the checksum changed only the cost.
*/

// The defaults are the play sandbox on the biome the wizard starts in,
// and enough ticks that the timer is not measuring its own noise.
Options :: struct {
	biome: string,
	size:  i32,
	ticks: int,
	warm:  int, // ticks run before the clock starts
}

main :: proc() {
	// The image loader logs to standard output, and the numbers are
	// the only thing worth reading here.
	game.mcp_silence_graphics_log()

	options := Options {
		biome = "Coalmine",
		size  = game.SANDBOX_PLAY_SIZE,
		ticks = 100,
		warm  = 10,
	}
	if !read_options(&options) do os.exit(1)

	sim: game.Sim
	if err := game.sim_load(&sim); err != .None {
		fmt.eprintfln("the game could not start: %v", err)
		os.exit(1)
	}
	defer game.sim_unload(&sim)

	index, found := game.find_biome_index(sim.world.biomes, options.biome)
	if !found {
		fmt.eprintfln("there is no biome named %q", options.biome)
		os.exit(1)
	}
	x, y, _ := game.shot_biome_origin(sim.world, game.Biome_Id(index))

	if err := game.sim_open_sandbox(&sim, options.size, options.size, x, y, 7, 0); err != .None {
		fmt.eprintfln("a %dx%d sandbox could not be opened: %v", options.size, options.size, err)
		os.exit(1)
	}

	// The first ticks of a fresh sandbox are not a tick of play: the
	// generator leaves grains resting on nothing, and they all fall at
	// once. Run those before the clock starts.
	game.sim_run(&sim, options.warm)

	start := time.now()
	game.sim_run(&sim, options.ticks)
	spent := time.duration_milliseconds(time.since(start))

	fmt.printfln(
		"%s %dx%d: %.3f ms a tick, over %d ticks (checksum 0x%016x)",
		options.biome,
		options.size,
		options.size,
		spent / f64(options.ticks),
		options.ticks,
		game.sandbox_checksum(&sim.sandbox),
	)
}

read_options :: proc(options: ^Options) -> bool {
	for argument in os.args[1:] {
		eq := strings.index_byte(argument, '=')
		if eq < 0 {
			fmt.eprintfln("arguments are key=value, and %q is not", argument)
			return false
		}

		key := argument[:eq]
		value := argument[eq + 1:]

		number :: proc(key, value: string, least: i64) -> (i64, bool) {
			v, ok := strconv.parse_i64(value)
			if !ok || v < least {
				fmt.eprintfln("%s wants a whole number of %d or more, and %q is not one", key, least, value)
				return 0, false
			}
			return v, true
		}

		ok := true
		v: i64
		switch key {
		case "biome":
			options.biome = value
		case "size":
			v, ok = number(key, value, 1)
			options.size = i32(v)
		case "ticks":
			v, ok = number(key, value, 1)
			options.ticks = int(v)
		case "warm":
			v, ok = number(key, value, 0)
			options.warm = int(v)
		case:
			fmt.eprintfln("there is no argument %q", key)
			return false
		}
		if !ok do return false
	}
	return true
}
