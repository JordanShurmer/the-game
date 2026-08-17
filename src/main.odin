package game

import "core:fmt"
import "core:os"
import rl "vendor:raylib"

/*
The game window.

The world view is a texture the size of the window. One texel is
`step` world cells. The app asks the generator for exactly the
rectangle it is about to show, and nothing more. There is no chunk
store yet, because nothing needs one.
*/

WINDOW_W :: 1280
WINDOW_H :: 720

MATERIALS_PATH :: "data/materials.txt"
BIOMES_PATH :: "data/biomes.txt"

// The map starts this big when there is no image on disk yet.
STARTER_MAP_W :: 16
STARTER_MAP_H :: 16

App :: struct {
	world:     World,
	editor:    Editor,

	// Camera. cam_x and cam_y are the world cell at the top-left texel.
	cam_x:     i32,
	cam_y:     i32,
	step:      i32, // world cells per screen pixel

	// The view buffers. cells holds material ids; pixels holds what
	// the texture shows. Both are the size of the window.
	cells:     []Cell,
	pixels:    []rl.Color,
	texture:   rl.Texture2D,

	// A material id maps to a color through this table. It is small
	// and read once per texel, so it stays hot.
	color_lut: [256]rl.Color,

	dirty:     bool,
}

BACKGROUND :: rl.Color{18, 20, 26, 255}

main :: proc() {
	app: App
	if !app_load_data(&app) {
		os.exit(1)
	}
	defer app_unload_data(&app)

	rl.SetTraceLogLevel(.WARNING)
	rl.InitWindow(WINDOW_W, WINDOW_H, "The Game - biome generation")
	defer rl.CloseWindow()
	rl.SetTargetFPS(60)

	app_init_view(&app)
	defer app_destroy_view(&app)

	for !rl.WindowShouldClose() {
		app_handle_input(&app)

		if app.dirty {
			app_regenerate(&app)
			app.dirty = false
		}

		rl.BeginDrawing()
		rl.ClearBackground(BACKGROUND)
		rl.DrawTexture(app.texture, 0, 0, rl.WHITE)
		draw_hud(&app)
		editor_draw(&app)
		rl.EndDrawing()

		free_all(context.temp_allocator)
	}
}

/*
Load the data files. Every failure here is fatal and says what is
wrong, because a half-loaded world is worse than no world.
*/
app_load_data :: proc(app: ^App) -> bool {
	materials, mat_ok := load_materials(MATERIALS_PATH)
	if !mat_ok {
		fmt.eprintfln("cannot read %s (run the game from the repo root)", MATERIALS_PATH)
		return false
	}

	biomes, err, line := load_biomes(BIOMES_PATH, materials)
	if err != .None {
		fmt.eprintfln("%s: %v at line %d", BIOMES_PATH, err, line)
		destroy_material_table(materials)
		return false
	}

	tiles, tiles_ok := load_or_create_tile_set(biomes, materials)
	if !tiles_ok {
		destroy_biome_table(biomes)
		destroy_material_table(materials)
		return false
	}

	bmap, ok := load_or_create_biome_map(biomes)
	if !ok {
		destroy_tile_set(tiles)
		destroy_biome_table(biomes)
		destroy_material_table(materials)
		return false
	}

	app.world = World {
		materials = materials,
		biomes    = biomes,
		biome_map = bmap,
		tiles     = tiles,
		seed      = 1,
	}

	for m, i in materials.materials {
		app.color_lut[i] = rl_from_argb(m.color)
	}

	app.step = 8 // pulled back far enough to see whole regions
	app.cam_x = -(WINDOW_W / 2) * app.step
	app.cam_y = -(WINDOW_H / 2) * app.step
	app.dirty = true

	editor_init(app)
	return true
}

app_unload_data :: proc(app: ^App) {
	editor_destroy(app)
	destroy_tile_set(app.world.tiles)
	destroy_biome_map(app.world.biome_map)
	destroy_biome_table(app.world.biomes)
	destroy_material_table(app.world.materials)
}

/*
Read every authored tile, and write a flat one for any tile the data
file names but nobody has painted yet.

This is the same bargain load_or_create_biome_map makes: a fresh
checkout opens on a world you can see, and the files it writes are the
files the editor saves.
*/
load_or_create_tile_set :: proc(
	biomes: Biome_Table,
	materials: Material_Table,
) -> (
	set: Tile_Set,
	ok: bool,
) {
	loaded, result, id := load_tile_set(biomes, materials, true)
	if result.err == .None do return loaded, true

	path := biomes.tile_paths[id]
	switch result.err {
	case .Unmatched_Color:
		fmt.eprintfln(
			"%s: pixel (%d,%d) has color %08X, which no material in %s claims",
			path,
			result.x,
			result.y,
			result.color,
			MATERIALS_PATH,
		)
	case .Wrong_Size:
		fmt.eprintfln(
			"%s: the tile is %dx%d, but every tile must be %dx%d",
			path,
			result.x,
			result.y,
			i32(TILE_SIZE),
			i32(TILE_SIZE),
		)
	case .File_Unreadable:
		fmt.eprintfln("cannot read or write %s", path)
	case .None:
	}
	return {}, false
}

/*
Read the map image, or paint a starter map and write it. A new
checkout then opens on a world you can see, and the file it writes is
the same file the editor saves.
*/
load_or_create_biome_map :: proc(biomes: Biome_Table) -> (m: Biome_Map, ok: bool) {
	path := biomes.map_image_path

	if os.exists(path) {
		loaded, result := load_biome_map_png(path, biomes)
		if result.err == .Unmatched_Color {
			fmt.eprintfln(
				"%s: pixel (%d,%d) has color %08X, which no biome in %s claims",
				path,
				result.x,
				result.y,
				result.color,
				BIOMES_PATH,
			)
			return {}, false
		}
		if result.err != .None {
			fmt.eprintfln("%s: %v", path, result.err)
			return {}, false
		}
		return loaded, true
	}

	m = make_starter_biome_map(biomes)
	if !save_biome_map_png(m, biomes, path) {
		fmt.eprintfln("cannot write %s", path)
		destroy_biome_map(m)
		return {}, false
	}
	fmt.printfln("wrote a starter map to %s", path)
	return m, true
}

/*
A layered starter world: sky over a mine, sand and a lake below it,
then oil, and deep rock at the bottom. Every pixel is painted, so the
map is connected and can be saved as it is.
*/
make_starter_biome_map :: proc(biomes: Biome_Table) -> Biome_Map {
	m := make_biome_map(STARTER_MAP_W, STARTER_MAP_H)

	id_of :: proc(biomes: Biome_Table, name: string) -> Biome_Id {
		idx, found := find_biome_index(biomes, name)
		assert(found, "the starter map names a biome that data/biomes.txt does not define")
		return Biome_Id(idx)
	}

	sky := id_of(biomes, "Sky")
	mine := id_of(biomes, "Coalmine")
	sand := id_of(biomes, "Sandcave")
	lake := id_of(biomes, "Lake")
	oil := id_of(biomes, "Oilfield")
	acid := id_of(biomes, "Acidpool")
	magma := id_of(biomes, "Magma")
	vault := id_of(biomes, "Vault")
	deep := id_of(biomes, "Deep_Rock")

	band :: proc(m: Biome_Map, y0, y1: i32, id: Biome_Id) {
		for y in y0 ..= y1 {
			for x in i32(0) ..< m.width do biome_map_set(m, x, y, id)
		}
	}
	blob :: proc(m: Biome_Map, x0, y0, x1, y1: i32, id: Biome_Id) {
		for y in y0 ..= y1 {
			for x in x0 ..= x1 do biome_map_set(m, x, y, id)
		}
	}

	band(m, 0, 2, sky)
	band(m, 3, 6, mine)
	band(m, 7, 9, sand)
	band(m, 10, 12, oil)
	band(m, 13, 15, deep)

	blob(m, 10, 7, 13, 8, lake)
	blob(m, 2, 11, 4, 12, acid)
	blob(m, 6, 14, 9, 15, magma)
	blob(m, 13, 13, 13, 13, vault)

	return m
}

app_init_view :: proc(app: ^App) {
	app.cells = make([]Cell, WINDOW_W * WINDOW_H)
	app.pixels = make([]rl.Color, WINDOW_W * WINDOW_H)

	blank := rl.Image {
		data    = raw_data(app.pixels),
		width   = WINDOW_W,
		height  = WINDOW_H,
		mipmaps = 1,
		format  = .UNCOMPRESSED_R8G8B8A8,
	}
	app.texture = rl.LoadTextureFromImage(blank)
}

app_destroy_view :: proc(app: ^App) {
	rl.UnloadTexture(app.texture)
	delete(app.cells)
	delete(app.pixels)
}

/*
Generate what the window shows, then turn material ids into colors.

This is the one generate path. The editor calls it after every paint
stroke, and the game calls it after every camera move.
*/
app_regenerate :: proc(app: ^App) {
	view := World_View {
		x    = app.cam_x,
		y    = app.cam_y,
		w    = WINDOW_W,
		h    = WINDOW_H,
		step = app.step,
	}
	generate(app.world, view, app.cells)

	for c, i in app.cells {
		app.pixels[i] = app.color_lut[c]
	}
	rl.UpdateTexture(app.texture, raw_data(app.pixels))
}

app_handle_input :: proc(app: ^App) {
	if rl.IsKeyPressed(.TAB) {
		app.editor.open = !app.editor.open
		if app.editor.open do editor_refresh(app)
	}

	if app.editor.open {
		editor_handle_input(app)
		return
	}

	// Pan. The speed follows the zoom, so the world moves at the same
	// rate on screen whatever the step is.
	pan := 8 * app.step
	moved := false
	if rl.IsKeyDown(.LEFT) || rl.IsKeyDown(.A) {app.cam_x -= pan;moved = true}
	if rl.IsKeyDown(.RIGHT) || rl.IsKeyDown(.D) {app.cam_x += pan;moved = true}
	if rl.IsKeyDown(.UP) || rl.IsKeyDown(.W) {app.cam_y -= pan;moved = true}
	if rl.IsKeyDown(.DOWN) || rl.IsKeyDown(.S) {app.cam_y += pan;moved = true}

	// Zoom about the middle of the window, so the view does not jump.
	zoom := 0
	if rl.IsKeyPressed(.EQUAL) || rl.IsKeyPressed(.KP_ADD) do zoom = -1
	if rl.IsKeyPressed(.MINUS) || rl.IsKeyPressed(.KP_SUBTRACT) do zoom = 1
	if wheel := rl.GetMouseWheelMove(); wheel > 0 {
		zoom = -1
	} else if wheel < 0 {
		zoom = 1
	}

	if zoom != 0 {
		old := app.step
		new_step := zoom < 0 ? old / 2 : old * 2
		new_step = clamp(new_step, 1, 256)
		if new_step != old {
			cx := app.cam_x + (WINDOW_W / 2) * old
			cy := app.cam_y + (WINDOW_H / 2) * old
			app.step = new_step
			app.cam_x = cx - (WINDOW_W / 2) * new_step
			app.cam_y = cy - (WINDOW_H / 2) * new_step
			moved = true
		}
	}

	if moved do app.dirty = true
}

draw_hud :: proc(app: ^App) {
	if app.editor.open do return

	cx := app.cam_x + (WINDOW_W / 2) * app.step
	cy := app.cam_y + (WINDOW_H / 2) * app.step
	id := world_biome_at(app.world, cx, cy)
	b := app.world.biomes.biomes[id]

	rl.DrawRectangle(0, 0, 460, 100, rl.Fade(rl.BLACK, 0.55))
	rl.DrawText(fmt.ctprintf("cell %d, %d   1px = %d cells", cx, cy, app.step), 12, 10, 18, rl.RAYWHITE)
	rl.DrawText(
		fmt.ctprintf("biome at centre: %s", app.world.biomes.names[id]),
		12,
		32,
		18,
		rl_from_argb(b.key_color),
	)

	// What the cell under the crosshair is made of. A tile biome shows
	// a different material every few cells, so the biome name alone no
	// longer says what you are looking at.
	cell := world_cell_at(app.world, cx, cy)
	source := b.tile == TILE_NONE ? "fill" : "tile"
	rl.DrawText(
		fmt.ctprintf("material: %s (%s)", app.world.materials.names[cell], source),
		12,
		54,
		18,
		rl_from_argb(app.world.materials.materials[cell].color | 0xFF000000),
	)
	rl.DrawText("WASD pan   wheel zoom   TAB world editor", 12, 76, 16, rl.GRAY)
}
