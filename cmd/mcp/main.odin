package main

import "core:fmt"
import "core:os"

import game "../../src"

/*
The MCP server for the game.

The server talks JSON-RPC 2.0 over standard input and standard
output, which is what an MCP client starts and connects to.

It loads the same world the game window loads, through the same
procedure, and it edits that world through the same procedures the
mouse calls. The only thing it does not have is a window.

Usage:
	game-mcp [materials-file] [biomes-file]

The data paths are relative, so run the server from the repository
root.
*/

main :: proc() {
	// Before anything reads a file: the image loader logs to standard
	// output, and standard output is the wire.
	game.mcp_silence_graphics_log()

	materials := game.MATERIALS_PATH
	biomes := game.BIOMES_PATH
	if len(os.args) > 1 do materials = os.args[1]
	if len(os.args) > 2 do biomes = os.args[2]

	sim: game.Sim
	if err := game.sim_load(&sim, materials, biomes); err != .None {
		fmt.eprintfln("the game could not start: %v", err)
		os.exit(1)
	}
	defer game.sim_unload(&sim)

	fmt.eprintfln(
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
