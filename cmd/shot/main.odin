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
	ticks   open a sandbox on exactly x,y,w,h and run this many
	        ticks before drawing, instead of drawing the world as
	        the generator paints it. Needs step=1 and w,h inside
	        SANDBOX_MAX_WIDTH/HEIGHT.
	ignite  x,y[,r]         set light material alight there before
	                        the ticks run. Needs ticks.
	explode x,y[,r][,power] set off a blast there before the ticks
	                        run. Needs ticks.

This is the check on the sprite and its collision box lining up:
player=1 draws through the same Sprite_Sheet and the same
sprite_frame_origin the game window will later use, so a wizard who is
off by a cell here would be off by a cell there too.

	./bin/shot biome=Gallery out=shots/gallery.png               # as painted
	./bin/shot biome=Gallery ticks=600 out=shots/g600.png        # after 10 seconds
	./bin/shot biome=Gallery x=0 y=-2560 w=128 h=128 scale=2 \
	           ticks=300 ignite=64,64,4 out=shots/room11.png     # light the gunpowder first

The data paths are relative, so run it from the repository root.
*/

// Defaults for explode= when a radius or a power is left out. Chosen so
// the default reads as a fair-sized blast rather than a firecracker:
// power/4 is the same ratio sandbox_ignite_cell uses to turn a lit
// explosive's own power into the radius of the blast it sets off.
EXPLODE_DEFAULT_POWER  :: 64
EXPLODE_DEFAULT_RADIUS :: EXPLODE_DEFAULT_POWER / 4

Point_Command :: struct {
	x, y, r: i32,
	power:   u8, // Explode only
	set:     bool,
}

Options :: struct {
	out:     string,
	biome:   string,
	x:       i32,
	y:       i32,
	w:       i32,
	h:       i32,
	step:    i32,
	scale:   i32,
	grid:    bool,
	player:  bool,
	aimed:   bool, // x or y was given, so a biome or the player must not move the camera
	ticks:      i32,
	ticks_set:  bool, // the key was given at all; ticks=0 still opens a sandbox
	ignite:     Point_Command,
	explode:    Point_Command,
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

	view := game.World_View{x = options.x, y = options.y, w = options.w, h = options.h, step = options.step}

	if !options.ticks_set && (options.ignite.set || options.explode.set) {
		fmt.eprintfln("ignite and explode need ticks=N too, so there is a sandbox to place them in")
		os.exit(1)
	}

	if options.ticks_set {
		// See docs/physics.md, "Looking at it": the rectangle a shot with
		// ticks= draws is the exact rectangle it opens the sandbox on.
		if err := game.shot_open_sandbox(&sim, view); err != .None {
			switch err {
			case .Wrong_Step:
				fmt.eprintfln("ticks needs step=1 (a sandbox is one cell per cell), got step=%d", options.step)
			case .Too_Large:
				fmt.eprintfln(
					"ticks needs a rectangle no larger than %dx%d cells, got %dx%d",
					game.SANDBOX_MAX_WIDTH, game.SANDBOX_MAX_HEIGHT, options.w, options.h,
				)
			case .Open_Failed:
				fmt.eprintfln("the sandbox could not be opened on world (%d,%d) %dx%d", options.x, options.y, options.w, options.h)
			case .None:
			}
			os.exit(1)
		}

		// Both go through sim_apply, the one procedure a hand-driven
		// window and every MCP tool also call (docs/physics.md, "one
		// path for a hand and a model"), rather than calling
		// sandbox_ignite/sandbox_explode directly. A shot runs to
		// completion in one process with nobody else to keep in step
		// with, so there is no reason to route them through the input
		// queue's delay: they are applied at once, before the ticks run.
		if options.ignite.set {
			game.sim_apply(&sim, game.Input_Command{
				kind   = .Ignite,
				x      = options.ignite.x - options.x,
				y      = options.ignite.y - options.y,
				radius = u16(options.ignite.r),
			})
		}
		if options.explode.set {
			game.sim_apply(&sim, game.Input_Command{
				kind     = .Explode,
				x        = options.explode.x - options.x,
				y        = options.explode.y - options.y,
				radius   = u16(options.explode.r),
				material = u16(options.explode.power),
			})
		}

		game.sim_run(&sim, int(options.ticks))
	}

	shot := game.Shot {
		view  = view,
		scale = options.scale,
		grid  = options.grid,
	}
	if options.ticks_set {
		shot.sandbox = &sim.sandbox
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
		case "ticks":
			options.ticks, ok = number(key, value)
			options.ticks_set = true
		case "ignite":
			options.ignite, ok = point_command(key, value, 0, 0)
		case "explode":
			options.explode, ok = point_command(key, value, EXPLODE_DEFAULT_RADIUS, EXPLODE_DEFAULT_POWER)
		case:
			fmt.eprintfln("there is no argument %q", key)
			return false
		}
		if !ok do return false
	}
	return true
}

// Parses "x,y[,r]" or "x,y[,r][,power]": a comma separated list of two
// to four whole numbers, with a radius and (for explode=) a power that
// fall back to the given defaults when they are left out.
point_command :: proc(key, value: string, default_r: i32, default_power: u8) -> (Point_Command, bool) {
	parts := strings.split(value, ",", context.temp_allocator)
	if len(parts) < 2 || len(parts) > 4 {
		fmt.eprintfln("%s wants x,y[,r][,power], and %q is not that shape", key, value)
		return {}, false
	}

	nums: [4]i64
	for part, i in parts {
		v, ok := strconv.parse_i64(part)
		if !ok {
			fmt.eprintfln("%s wants whole numbers, and %q is not one", key, part)
			return {}, false
		}
		nums[i] = v
	}

	out := Point_Command{
		x     = i32(nums[0]),
		y     = i32(nums[1]),
		r     = len(parts) > 2 ? i32(nums[2]) : default_r,
		power = len(parts) > 3 ? u8(clamp(nums[3], 0, 255)) : default_power,
		set   = true,
	}
	return out, true
}
