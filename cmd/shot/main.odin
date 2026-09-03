package main

// The world as a PNG, with no window.
//
//   ./bin/shot biome=Coalmine grid=1 out=shots/coalmine.png
//
// The result is one line: the file it wrote, and what is in it.
// Everything else waits for a rung of the debug ladder; see
// src/noise.odin.

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"

import game "../../src"

EXPLODE_DEFAULT_POWER  :: 64
EXPLODE_DEFAULT_RADIUS :: EXPLODE_DEFAULT_POWER / 4

USAGE :: `usage: shot [key=value ...]

  out      where to write the PNG          (shots/world.png)
  biome    aim at a biome in data/biomes.txt
  x= y=    aim at a world cell instead
  w= h=    the rectangle, in cells         (384x256)
  step     world cells per texel           (1)
  scale    texels per pixel                (2)
  grid     1 to draw the tile lattice
  player   1 to put the wizard in the frame
  light    1 or 0 to force the light on or off
  walk     step the wizard this many ticks, left if negative
  ticks    open a sandbox and run it this many ticks
  ignite   x,y[,r]          needs ticks=N
  explode  x,y[,r][,power]  needs ticks=N
  seed     which world to open; seed=0x1AB is the Laboratory
  debug    0 the result, 1 the steps, 2 the detail, 3 everything

Run it from the repository root: the data paths are relative to it.`

Point_Command :: struct {
	x, y, r: i32,
	power:   u8,
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
	aimed:   bool,
	light:      bool,
	light_set:  bool,
	walk:       i32,
	ticks:      i32,
	ticks_set:  bool,
	ignite:     Point_Command,
	explode:    Point_Command,
	seed:       Maybe(u64),
}

main :: proc() {

	options := Options {
		out   = "shots/world.png",
		w     = 384,
		h     = 256,
		step  = 1,
		scale = 2,
	}
	if !read_options(&options) {
		fmt.eprintln(USAGE)
		os.exit(1)
	}

	if options.walk != 0 do options.player = true
	if !options.light_set do options.light = options.player

	game.say(game.NOISE_STEP, "loading the world")
	sim: game.Sim
	if err := game.sim_load(&sim, seed = options.seed); err != .None {
		fmt.eprintfln("the world could not load: %v", err)
		os.exit(1)
	}
	defer game.sim_unload(&sim)

	sheet: game.Sprite_Sheet
	defer game.destroy_sprite_sheet(sheet)

	drudge_sheet, drudge_result := game.load_drudge_sprite_sheet()
	if drudge_result.err != .None {
		fmt.eprintfln("the drudge sprite sheet could not load: %v", drudge_result.err)
		os.exit(1)
	}
	defer game.destroy_sprite_sheet(drudge_sheet)

	player: game.Player
	if options.player {
		result: game.Sprite_Load_Result
		sheet, result = game.load_sprite_sheet(game.SPRITE_SHEET_PATH)
		if result.err != .None {
			fmt.eprintfln("the sprite sheet could not load: %v", result.err)
			os.exit(1)
		}

		player = game.player_spawn(&sim.world)
		player.on_ground = true

		if !options.aimed && options.biome == "" {
			options.x = i32(player.x) - options.w * options.step / 2
			options.y = i32(player.y) - options.h * options.step / 2
		}
	}

	if options.walk != 0 {
		game.say(game.NOISE_STEP, "walking the wizard %d ticks", options.walk)
		if options.ticks_set {
			fmt.eprintfln("walk and ticks both drive the simulation, so use one or the other")
			os.exit(1)
		}

		game.sim_play_begin(&sim)
		held: game.Player_Input = options.walk > 0 ? {.Right} : {.Left}
		for _ in 0 ..< abs(options.walk) {
			game.sim_step_player(&sim, held, false)
		}
		player = sim.player

		if !options.aimed {
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
			fmt.eprintfln("%s", game.biome_not_on_this_map(sim.world.biomes, sim.world.seed, options.biome))
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

		game.say(game.NOISE_STEP, "running the sandbox %d ticks", options.ticks)
		game.sim_run(&sim, int(options.ticks))
	}

	shot := game.Shot {
		view  = view,
		scale = options.scale,
		grid  = options.grid,
	}
	if options.ticks_set || options.walk != 0 {
		shot.sandbox = &sim.sandbox
	}
	if options.player {
		shot.player = player
		shot.sprite = sheet
	}
	shot.drudges = &sim.drudges
	shot.drudge_pots = &sim.drudge_pots
	shot.drudge_sprite = drudge_sheet

	if options.light {
		terrain := game.Terrain{world = &sim.world, sandbox = shot.sandbox}
		// The light is the whole map, placed at load, so there is nothing
		// to follow: a room lit by nothing but the sparks of its own
		// reaction is lit wherever it is.
		game.light_step(&sim.light, terrain, player, &sim.flies, &sim.pots, &sim.drudge_pots, &sim.drudges)
		shot.light = &sim.light
		shot.flies = &sim.flies
		shot.pots = &sim.pots
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
		case "debug":
			rung: i32
			rung, ok = number(key, value)
			game.noise_set(int(rung))
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
		case "light":
			options.light = value != "0" && value != "false"
			options.light_set = true
		case "walk":
			options.walk, ok = number(key, value)
		case "ticks":
			options.ticks, ok = number(key, value)
			options.ticks_set = true
		case "ignite":
			options.ignite, ok = point_command(key, value, 0, 0)
		case "explode":
			options.explode, ok = point_command(key, value, EXPLODE_DEFAULT_RADIUS, EXPLODE_DEFAULT_POWER)
		case "seed":
			// A seed is a world, and hexadecimal is a seed too:
			// seed=0x1AB opens the Laboratory. See docs/laboratory.md.
			v, seed_ok := game.parse_seed(value)
			if !seed_ok {
				fmt.eprintfln("seed wants a whole number that fits in 64 bits, and %q is not one", value)
				return false
			}
			options.seed = v
		case:
			fmt.eprintfln("there is no argument %q", key)
			return false
		}
		if !ok do return false
	}
	return true
}

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
