package main

// What a tick costs, on a real region of the shipped world.
//
//   ./bin/bench biome=Lake ticks=300
//
// The result is the cost of a tick, the checksum that says the run was
// the same run, and the shape of the time under it: which phases the
// tick went to, widest first, and how much matter it worked. That is
// what a bench is for, so it prints with no argument.
//
// The same numbers at full width, one phase to a line, are the detail
// behind it and wait for debug=2. See src/noise.odin for the ladder.

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"

import game "../../src"

USAGE :: `usage: bench [biome=NAME] [size=N] [ticks=N] [warm=N] [seed=N] [debug=0..3]

  biome  a name in data/biomes.txt      (Coalmine)
  size   the sandbox edge, in cells     (the play size)
  ticks  how many ticks to time         (100)
  warm   how many ticks to throw away   (10)
  seed   which world to open; seed=0x1AB is the Laboratory
  debug  0 the result, 1 the steps, 2 the phase table, 3 everything

Run it from the repository root: the data paths are relative to it.`

Options :: struct {
	biome: string,
	size:  i32,
	ticks: int,
	warm:  int,
	seed:  Maybe(u64),
}

main :: proc() {
	options := Options {
		biome = "Coalmine",
		size  = game.SANDBOX_PLAY_SIZE,
		ticks = 100,
		warm  = 10,
	}
	if !read_options(&options) {
		fmt.eprintln(USAGE)
		os.exit(1)
	}

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

	game.say(game.NOISE_STEP, "warming %d ticks", options.warm)
	game.sim_run(&sim, options.warm)
	game.prof_reset()

	game.say(game.NOISE_STEP, "timing %d ticks", options.ticks)

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
	// The breakdown is part of the result: a total alone says which
	// runs differ without saying where.
	fmt.print(game.prof_brief(game.prof, context.temp_allocator))

	// The same numbers at full width, for a reader who has found the
	// phase and wants it exact.
	if game.noise_level() >= game.NOISE_DETAIL {
		fmt.eprint(game.prof_report(game.prof, context.temp_allocator))
	}
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
		case "debug":
			v, ok = number(key, value, 0)
			game.noise_set(int(v))
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
			seed, seed_ok := game.parse_seed(value)
			if !seed_ok {
				fmt.eprintfln("seed wants a whole number that fits in 64 bits, and %q is not one", value)
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
