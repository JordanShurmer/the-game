package main

import "core:fmt"
import "core:os"

import game "../../src"

main :: proc() {
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
