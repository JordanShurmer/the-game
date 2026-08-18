package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import rl "vendor:raylib"

import game "../../src"

/*
Draw a rectangle of the authored world into a PNG file.

This is how to look at the world without a window. It loads the same
data the game loads and draws through the same generate path the game
window draws through, so the picture is what a player would see.

	make shot
	./bin/shot biome=Coalmine grid=1 out=shots/coalmine.png

Arguments are key=value in any order:

	out    where to write the PNG               (shots/world.png)
	biome  aim at the first region of this biome
	x y    world cell at the top left           (0 0, or the biome)
	w h    size of the picture in texels        (384 256)
	step   world cells per texel                (1)
	scale  image pixels per texel               (2)
	grid   1 draws the tile lattice and the region borders (0)

The data paths are relative, so run it from the repository root.
*/

Options :: struct {
	out:   string,
	biome: string,
	x:     i32,
	y:     i32,
	w:     i32,
	h:     i32,
	step:  i32,
	scale: i32,
	grid:  bool,
	aimed: bool, // x or y was given, so a biome must not move the camera
}

main :: proc() {
	// The image loader reports every file it reads. A picture is the
	// only thing this tool has to say.
	rl.SetTraceLogLevel(.WARNING)

	options := Options {
		out   = "shots/world.png",
		w     = 384,
		h     = 256,
		step  = 1,
		scale = 2,
	}
	if !read_options(&options) do os.exit(1)

	sim: game.Sim
	if err := game.sim_load(&sim); err != .None {
		fmt.eprintfln("the world could not load: %v", err)
		os.exit(1)
	}
	defer game.sim_unload(&sim)

	if options.biome != "" {
		idx, found := game.find_biome_index(sim.world.biomes, options.biome)
		if !found {
			fmt.eprintfln("there is no biome %q in %s", options.biome, game.BIOMES_PATH)
			os.exit(1)
		}
		x, y, aimed := game.shot_biome_origin(sim.world, game.Biome_Id(idx))
		if !aimed {
			fmt.eprintfln("%s is not painted on the biome map yet", options.biome)
			os.exit(1)
		}
		if !options.aimed {
			options.x = x
			options.y = y
		}
	}

	shot := game.Shot {
		view = game.World_View {
			x = options.x,
			y = options.y,
			w = options.w,
			h = options.h,
			step = options.step,
		},
		scale = options.scale,
		grid = options.grid,
	}

	if !game.world_shot(sim.world, shot, options.out) {
		fmt.eprintfln(
			"cannot write %s (does the directory exist, and is %dx%d at scale %d too large?)",
			options.out,
			options.w,
			options.h,
			options.scale,
		)
		os.exit(1)
	}

	fmt.printfln(
		"%s: world (%d,%d) %dx%d cells at %d per texel, %dx%d pixels",
		options.out,
		options.x,
		options.y,
		options.w * options.step,
		options.h * options.step,
		options.step,
		options.w * options.scale,
		options.h * options.scale,
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

		number :: proc(key, value: string) -> (i32, bool) {
			v, ok := strconv.parse_i64(value)
			if !ok {
				fmt.eprintfln("%s wants a whole number, and %q is not one", key, value)
				return 0, false
			}
			return i32(v), true
		}

		ok := true
		switch key {
		case "out":
			options.out = value
		case "biome":
			options.biome = value
		case "x":
			options.x, ok = number(key, value)
			options.aimed = true
		case "y":
			options.y, ok = number(key, value)
			options.aimed = true
		case "w":
			options.w, ok = number(key, value)
		case "h":
			options.h, ok = number(key, value)
		case "step":
			options.step, ok = number(key, value)
		case "scale":
			options.scale, ok = number(key, value)
		case "grid":
			options.grid = value != "0" && value != "false"
		case:
			fmt.eprintfln("there is no argument %q", key)
			return false
		}
		if !ok do return false
	}
	return true
}
