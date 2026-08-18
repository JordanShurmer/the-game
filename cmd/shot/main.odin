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
	./bin/shot player=1 out=shots/wizard.png

Arguments are key=value in any order:

	out     where to write the PNG               (shots/world.png)
	biome   aim at the first region of this biome
	player  1 spawns the wizard and draws him standing at the cave
	        mouth, aiming the view at him unless x, y or biome say
	        otherwise                             (0)
	x y     world cell at the top left           (0 0, or wherever
	        player or biome aims the camera)
	w h     size of the picture in texels        (384 256)
	step    world cells per texel                (1)
	scale   image pixels per texel               (2)
	grid    1 draws the tile lattice and the region borders (0)

This is the check on the sprite and its collision box lining up:
player=1 draws through the same Sprite_Sheet and the same
sprite_frame_origin the game window will later use, so a wizard who is
off by a cell here would be off by a cell there too.

The data paths are relative, so run it from the repository root.
*/

Options :: struct {
	out:    string,
	biome:  string,
	x:      i32,
	y:      i32,
	w:      i32,
	h:      i32,
	step:   i32,
	scale:  i32,
	grid:   bool,
	player: bool,
	aimed:  bool, // x or y was given, so a biome or the player must not move the camera
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

	// Declared (and freed) here regardless of player=1, because Odin's
	// defer fires at the end of the scope it is written in, not the end
	// of the function: nesting the defer inside the `if options.player`
	// block below would free this sheet before world_shot ever reads
	// it. A zero-valued Sprite_Sheet has nil pixels, and destroying that
	// is a no-op, so this is safe whether or not player=1 was given.
	sheet: game.Sprite_Sheet
	defer game.destroy_sprite_sheet(sheet)

	player: game.Player
	if options.player {
		result: game.Sprite_Load_Result
		sheet, result = game.load_sprite_sheet(game.SPRITE_SHEET_PATH)
		if result.err != .None {
			fmt.eprintfln("the sprite sheet could not load: %v", result.err)
			os.exit(1)
		}

		player = game.player_spawn(sim.world)
		// player_spawn already lands him on solid ground: world_find_spawn
		// checks player_solid_at under his feet before it ever returns a
		// point. A shot draws one still instant with no physics tick to
		// discover that for itself the way player_step would on the
		// game's first tick, so this states outright what that tick would
		// otherwise compute, and draws him standing rather than mid-fall.
		player.on_ground = true

		// Aim the view at him unless the caller already aimed it some
		// other way. A wizard is 24x32 cells; the default view is 384x256
		// world cells starting at (0,0), and he spawns thousands of cells
		// from the origin, so without this the default view would almost
		// certainly not contain him at all.
		if !options.aimed && options.biome == "" {
			options.x = i32(player.x) - options.w * options.step / 2
			options.y = i32(player.y) - options.h * options.step / 2
		}
	}

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
	if options.player {
		shot.player = player
		shot.sprite = sheet
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
		case "player":
			options.player = value != "0" && value != "false"
		case:
			fmt.eprintfln("there is no argument %q", key)
			return false
		}
		if !ok do return false
	}
	return true
}
