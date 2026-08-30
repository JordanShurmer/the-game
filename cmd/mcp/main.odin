package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"

import game "../../src"

// Two paths and a world. The paths are positional and both have a
// default; `seed=N` may come anywhere among them, and `seed=0x1AB`
// serves the Laboratory instead of the ordinary world. See
// docs/laboratory.md.
main :: proc() {
	game.mcp_silence_graphics_log()

	materials := game.MATERIALS_PATH
	biomes := game.BIOMES_PATH
	seed: Maybe(u64)

	paths := 0
	for argument in os.args[1:] {
		if strings.has_prefix(argument, "seed=") {
			value := argument[len("seed="):]
			v, ok := strconv.parse_u64_maybe_prefixed(value)
			if !ok {
				fmt.eprintfln("seed wants a whole number, and %q is not one", value)
				os.exit(1)
			}
			seed = v
			continue
		}
		switch paths {
		case 0: materials = argument
		case 1: biomes = argument
		case:
			fmt.eprintfln("there is nothing for %q to be: the arguments are [materials] [biomes] [seed=N]", argument)
			os.exit(1)
		}
		paths += 1
	}

	sim: game.Sim
	if err := game.sim_load(&sim, materials, biomes, seed); err != .None {
		fmt.eprintfln("the game could not start: %v", err)
		os.exit(1)
	}
	defer game.sim_unload(&sim)

	fmt.eprintfln(
		"%s %s ready: %s seed %d, biome map %dx%d, sandbox %dx%d at world (%d,%d)",
		game.MCP_SERVER_NAME,
		game.MCP_SERVER_VERSION,
		game.world_is_laboratory(sim.world.biomes, sim.world.seed) ? "Laboratory" : "world",
		sim.world.seed,
		sim.world.biome_map.width,
		sim.world.biome_map.height,
		sim.sandbox.width,
		sim.sandbox.height,
		sim.sandbox.origin_x,
		sim.sandbox.origin_y,
	)

	game.mcp_serve(&sim)
}
