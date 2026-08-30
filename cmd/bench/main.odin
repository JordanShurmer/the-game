package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"

import game "../../src"

Options :: struct {
	biome: string,
	size:  i32,
	ticks: int,
	warm:  int,
	seed:  Maybe(u64),
}

main :: proc() {
	game.mcp_silence_graphics_log()

	options := Options {
		biome = "Coalmine",
		size  = game.SANDBOX_PLAY_SIZE,
		ticks = 100,
		warm  = 10,
	}
	if !read_options(&options) do os.exit(1)

	sim: game.Sim
	if err := game.sim_load(&sim, seed = options.seed); err != .None {
		fmt.eprintfln("the game could not start: %v", err)
		os.exit(1)
	}
	defer game.sim_unload(&sim)

	index, found := game.find_biome_index(sim.world.biomes, options.biome)
	if !found {
		fmt.eprintfln("there is no biome named %q", options.biome)
		os.exit(1)
	}
	// A biome the map this seed opens does not paint has no origin, and
	// benching world (0,0) under its name would read as a timing of it.
	x, y, painted := game.shot_biome_origin(sim.world, game.Biome_Id(index))
	if !painted {
		fmt.eprintfln("%s", game.biome_not_on_this_map(sim.world.biomes, sim.world.seed, options.biome))
		os.exit(1)
	}

	if err := game.sim_open_sandbox(&sim, options.size, options.size, x, y, 7, 0); err != .None {
		fmt.eprintfln("a %dx%d sandbox could not be opened: %v", options.size, options.size, err)
		os.exit(1)
	}

	game.sim_run(&sim, options.warm)
	game.prof_reset()

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
	fmt.print(game.prof_report(context.temp_allocator))
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
		case "seed":
			// A seed is a world, and hexadecimal is a seed too:
			// seed=0x1AB benches a room of the Laboratory.
			seed, seed_ok := strconv.parse_u64_maybe_prefixed(value)
			if !seed_ok {
				fmt.eprintfln("seed wants a whole number, and %q is not one", value)
				return false
			}
			options.seed = seed
		case:
			fmt.eprintfln("there is no argument %q", key)
			return false
		}
		if !ok do return false
	}
	return true
}
