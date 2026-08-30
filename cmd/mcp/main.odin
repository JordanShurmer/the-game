package main

// The MCP server. An MCP client starts this binary, and the two speak
// JSON-RPC over stdin and stdout.
//
//   ./bin/game-mcp [materials.txt [biomes.txt]]
//
// Nothing but the protocol may reach stdout, so every word this
// program says goes to stderr, and the graphics library is held to
// silence at every rung of the debug ladder. See src/noise.odin.

import "core:fmt"
import "core:os"

import game "../../src"

USAGE :: `usage: game-mcp [materials.txt [biomes.txt]]

Speaks MCP over stdin and stdout. An MCP client starts it; there is
nothing to read in a terminal. Set GAME_DEBUG=1..3 for more on stderr.`

main :: proc() {
	materials := game.MATERIALS_PATH
	biomes := game.BIOMES_PATH

	for argument in os.args[1:] {
		if argument == "-h" || argument == "--help" {
			fmt.eprintln(USAGE)
			os.exit(0)
		}
	}
	if len(os.args) > 3 {
		fmt.eprintln(USAGE)
		os.exit(1)
	}
	if len(os.args) > 1 do materials = os.args[1]
	if len(os.args) > 2 do biomes = os.args[2]

	// A trace line on stdout is a broken frame to the client, so the
	// server keeps the graphics log shut whatever the ladder says.
	game.mcp_silence_graphics_log()

	sim: game.Sim
	if err := game.sim_load(&sim, materials, biomes); err != .None {
		fmt.eprintfln("the game could not start: %v", err)
		os.exit(1)
	}
	defer game.sim_unload(&sim)

	game.say(
		game.NOISE_STEP,
		"%s %s ready: biome map %dx%d, sandbox %dx%d at world (%d,%d)",
		game.MCP_SERVER_NAME,
		game.MCP_SERVER_VERSION,
		sim.world.biome_map.width,
		sim.world.biome_map.height,
		sim.sandbox.width,
		sim.sandbox.height,
		sim.sandbox.origin_x,
		sim.sandbox.origin_y,
	)

	game.mcp_serve(&sim)
}
