package main

// The MCP server. An MCP client starts this binary, and the two speak
// JSON-RPC over stdin and stdout.
//
//   ./bin/game-mcp [materials.txt [biomes.txt]] [seed=N]
//
// Nothing but the protocol may reach stdout, so every word this
// program says goes to stderr, and the graphics library is held to
// silence at every rung of the debug ladder. See src/noise.odin.

import "core:fmt"
import "core:os"
import "core:strings"

import game "../../src"

USAGE :: `usage: game-mcp [materials.txt [biomes.txt]] [seed=N]

Speaks MCP over stdin and stdout. An MCP client starts it; there is
nothing to read in a terminal. Set GAME_DEBUG=1..3 for more on stderr.

The two paths are positional and both have a default. seed=N says
which world to serve, and may come anywhere among them: seed=0x1AB is
the Laboratory, where the two galleries are. See docs/laboratory.md.`

main :: proc() {
	materials := game.MATERIALS_PATH
	biomes := game.BIOMES_PATH
	seed: Maybe(u64)

	for argument in os.args[1:] {
		if argument == "-h" || argument == "--help" {
			fmt.eprintln(USAGE)
			os.exit(0)
		}
	}

	paths := 0
	for argument in os.args[1:] {
		if strings.has_prefix(argument, "seed=") {
			value := argument[len("seed="):]
			v, ok := game.parse_seed(value)
			if !ok {
				fmt.eprintfln("seed wants a whole number that fits in 64 bits, and %q is not one", value)
				fmt.eprintln(USAGE)
				os.exit(1)
			}
			seed = v
			continue
		}
		switch paths {
		case 0: materials = argument
		case 1: biomes = argument
		case:
			fmt.eprintfln("there is nothing for %q to be", argument)
			fmt.eprintln(USAGE)
			os.exit(1)
		}
		paths += 1
	}

	// A trace line on stdout is a broken frame to the client, so the
	// server keeps the graphics log shut whatever the ladder says.
	game.mcp_silence_graphics_log()

	sim: game.Sim
	if err := game.sim_load(&sim, materials, biomes, seed); err != .None {
		fmt.eprintfln("the game could not start: %v", err)
		os.exit(1)
	}
	defer game.sim_unload(&sim)

	game.say(
		game.NOISE_STEP,
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
