package game

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:strings"
import "core:testing"

MCP_MAX_MAP_CELLS :: 20000

MCP_TOOLS_JSON :: `{"tools":[
{"name":"world_status",
 "description":"Report the whole state: which world is open and its seed, the biome map, the open tile, the sandbox tick and checksum, the input queue counters, and how many cells hold each material.",
 "inputSchema":{"type":"object","properties":{},"additionalProperties":false}},
{"name":"list_materials",
 "description":"List every material with its index, map glyph, and physical properties. Use these names and glyphs when painting a tile or spawning into the sandbox.",
 "inputSchema":{"type":"object","properties":{},"additionalProperties":false}},
{"name":"list_biomes",
 "description":"List every biome with its id, map glyph, key color, generator, fill material, and tile file. Use these names and glyphs when painting the biome map.",
 "inputSchema":{"type":"object","properties":{},"additionalProperties":false}},
{"name":"biome_map_view",
 "description":"Read the biome map as a character grid. One character is one map pixel, which is one square region of the world. Also reports whether the map is connected, which is what gates saving.",
 "inputSchema":{"type":"object","properties":{},"additionalProperties":false}},
{"name":"biome_map_paint",
 "description":"Paint the biome map, the same way the mouse does in the world editor. Give either a rectangle and a biome, or rows of glyphs to stamp a picture. Painting changes the world at once; call sandbox_open to bring the change into the physics.",
 "inputSchema":{"type":"object","properties":{
   "x":{"type":"integer","description":"Left map pixel."},
   "y":{"type":"integer","description":"Top map pixel."},
   "width":{"type":"integer","description":"Rectangle width in map pixels. Default 1.","minimum":1},
   "height":{"type":"integer","description":"Rectangle height in map pixels. Default 1.","minimum":1},
   "biome":{"type":"string","description":"Biome name to paint. Use \"empty\" to clear a pixel back to the off-map biome. Ignored when rows are given."},
   "rows":{"type":"array","items":{"type":"string"},"description":"Rows of biome glyphs, stamped with the top-left corner at (x,y). A space or a dot leaves a pixel alone."}},
  "required":["x","y"],"additionalProperties":false}},
{"name":"biome_map_save",
 "description":"Write the biome map image. The save is blocked while the painted map falls into more than one connected region, which is the same gate the world editor applies.",
 "inputSchema":{"type":"object","properties":{},"additionalProperties":false}},
{"name":"tile_open",
 "description":"Open a biome's tile set for painting, the same way pressing T does in the world editor. A biome that fills flat has no set and says so. A set holds one tile for every combination of four edge colors, so the world can place them anywhere and never show a seam.",
 "inputSchema":{"type":"object","properties":{
   "biome":{"type":"string","description":"Biome name whose set to open."}},
  "required":["biome"],"additionalProperties":false}},
{"name":"tile_select",
 "description":"Choose which tile of the open set to paint. A tile is named by its four edge colors, north east south west, which is also the end of its file name.",
 "inputSchema":{"type":"object","properties":{
   "edges":{"type":"string","description":"Four digits, north east south west, each 0 or 1. For example \"0110\" is open on the east and the south."},
   "variant":{"type":"integer","description":"Which drawing of those four edges to paint. Default 0.","minimum":0}},
  "additionalProperties":false}},
{"name":"tile_view",
 "description":"Read the selected tile as a character grid of material glyphs, with its edge colors and which cells the seam rule shares with the rest of the set.",
 "inputSchema":{"type":"object","properties":{},"additionalProperties":false}},
{"name":"tile_paint",
 "description":"Paint the selected tile, the same way the mouse does in the tile editor. Give either a rectangle and a material, or rows of material glyphs to stamp a picture. A cell in the middle belongs to this tile; a cell within 4 of a side belongs to the edge color of that side and is written into every tile of the set that carries it. Every region of that biome in the world changes at once.",
 "inputSchema":{"type":"object","properties":{
   "x":{"type":"integer","description":"Left cell in the tile (0 to 511)."},
   "y":{"type":"integer","description":"Top cell in the tile (0 to 511)."},
   "width":{"type":"integer","description":"Rectangle width in cells. Default 1.","minimum":1},
   "height":{"type":"integer","description":"Rectangle height in cells. Default 1.","minimum":1},
   "material":{"type":"string","description":"Material name to paint. Ignored when rows are given."},
   "rows":{"type":"array","items":{"type":"string"},"description":"Rows of material glyphs, stamped with the top-left corner at (x,y). A space leaves a cell alone."}},
  "required":["x","y"],"additionalProperties":false}},
{"name":"tile_repair",
 "description":"Make the open set agree with itself again: for every cell two tiles share, the first tile that holds it wins. Only needed for files painted outside this editor, and it never touches the middle of a tile.",
 "inputSchema":{"type":"object","properties":{},"additionalProperties":false}},
{"name":"tile_save",
 "description":"Write every PNG of the open set. The images are the source, so any pixel editor can open them afterwards. The save is blocked while two tiles disagree about a cell they share; call tile_repair first.",
 "inputSchema":{"type":"object","properties":{},"additionalProperties":false}},
{"name":"sandbox_open",
 "description":"Fill the sandbox from a rectangle of the authored world and empty the input queue. Call it with no arguments to reload the same rectangle, which is how an edit to the map or a tile reaches the physics.",
 "inputSchema":{"type":"object","properties":{
   "x":{"type":"integer","description":"World cell at the left edge. Default: keep the current one."},
   "y":{"type":"integer","description":"World cell at the top edge. Default: keep the current one."},
   "width":{"type":"integer","description":"Sandbox width in cells (1 to 2048). Default: keep the current one.","minimum":1,"maximum":2048},
   "height":{"type":"integer","description":"Sandbox height in cells (1 to 2048). Default: keep the current one.","minimum":1,"maximum":2048},
   "biome":{"type":"string","description":"Instead of x and y, open on the first region the biome map gives this biome."},
   "seed":{"type":"integer","description":"Seed for the random source. The same seed repeats a run exactly. Default 1."},
   "input_delay":{"type":"integer","description":"Ticks between a command arriving and running (0 to 32). Default 2.","minimum":0,"maximum":32}},
  "additionalProperties":false}},
{"name":"enqueue_input",
 "description":"Put one command in the input queue. The command does not run now. It runs at the start of its execution tick, which the reply reports. Call tick to reach that tick. Coordinates are sandbox cells, not world cells.",
 "inputSchema":{"type":"object","properties":{
   "kind":{"type":"string","enum":["spawn","erase","ignite","explode","dig","move","noop"],"description":"spawn fills a disc with a material. erase clears a disc to air. ignite sets light material in a disc alight; it does nothing to empty air. explode casts rays from the point, breaking what power lets them reach; a wall casts a shadow. dig removes a disc of material soft enough for the given power; rock is hardness 8. move drives the wizard for one tick with buttons and pressed. noop holds a tick."},
   "x":{"type":"integer","description":"Centre column in the sandbox, or unused for move. 0 is the left edge."},
   "y":{"type":"integer","description":"Centre row in the sandbox, or unused for move. 0 is the top edge and y grows downward."},
   "radius":{"type":"integer","description":"Disc radius in cells, for spawn, erase, ignite, explode and dig. 0 writes one cell. Default 0.","minimum":0,"maximum":512},
   "material":{"type":"string","description":"Material name for spawn, as listed by list_materials. A Phantom state is a light and not matter, so no cell holds one and spawn refuses it."},
   "power":{"type":"integer","description":"Blast or dig power, for explode and dig. Explode: the energy a ray starts with; each cell it crosses costs hardness+1, so air costs 1 and bedrock stops any blast in one cell. Dig: the hardness that can be removed; the wizard digs at 8. Required for explode and dig.","minimum":0,"maximum":255},
   "buttons":{"type":"array","items":{"type":"string","enum":["left","right","jump","run","dig","throw"]},"description":"For move: which buttons are held this tick."},
   "pressed":{"type":"array","items":{"type":"string","enum":["left","right","jump","run","dig","throw"]},"description":"For move: which buttons went down fresh this tick, for the jump edge."},
   "aim":{"type":"number","description":"For move: where the digger points, in degrees. 0 is right, 90 is down, 180 is left, 270 is up, because y grows downward. Default: the way he faces.","minimum":0,"maximum":360},
   "source":{"type":"integer","description":"Sender number (0 to 7). Commands from different sources run in source order on the same tick. Default 0.","minimum":0,"maximum":7},
   "tick":{"type":"integer","description":"Exact execution tick. Leave this out to use the input delay. A tick that has already run is moved to the next tick and reported as late."}},
  "required":["kind"],"additionalProperties":false}},
{"name":"tick",
 "description":"Run the sandbox forward. Commands due on a tick run at the start of that tick, then the physics step runs. Reports the checksum and the material counts afterwards.",
 "inputSchema":{"type":"object","properties":{
   "count":{"type":"integer","description":"Ticks to run (1 to 100000). Default 1.","minimum":1,"maximum":100000}},
  "additionalProperties":false}},
{"name":"observe",
 "description":"Read a character map with a coordinate ruler and a legend, either of the sandbox as physics left it, or of the authored world as the generator makes it.",
 "inputSchema":{"type":"object","properties":{
   "source":{"type":"string","enum":["sandbox","world"],"description":"sandbox reads the running physics and uses sandbox coordinates. world reads the generator and uses world coordinates. Default sandbox."},
   "x":{"type":"integer","description":"Left column. Default: the left edge of the sandbox, or its world origin."},
   "y":{"type":"integer","description":"Top row. Default: the top edge of the sandbox, or its world origin."},
   "width":{"type":"integer","description":"Region width. Default: the sandbox width.","minimum":1},
   "height":{"type":"integer","description":"Region height. Default: the sandbox height.","minimum":1},
   "step":{"type":"integer","description":"World cells per character, for source=world only. Use a large step to see whole regions. Default 1.","minimum":1,"maximum":4096},
   "sample":{"type":"integer","description":"Cells per character, for source=sandbox only. Use 2 or more to fit a large sandbox in one answer. Default 1.","minimum":1,"maximum":64}},
  "additionalProperties":false}},
{"name":"queue_peek",
 "description":"List the commands that wait in the input queue, by execution tick, without running anything.",
 "inputSchema":{"type":"object","properties":{
   "ticks":{"type":"integer","description":"How many ticks ahead to look (1 to 64). Default 16.","minimum":1,"maximum":64}},
  "additionalProperties":false}},
{"name":"player_status",
 "description":"Report where the wizard is: his position, what he is standing on, his velocity, his jetpack fuel, and whether the play sandbox is following him.",
 "inputSchema":{"type":"object","properties":{},"additionalProperties":false}},
{"name":"player_move",
 "description":"Drive the wizard for a number of ticks with a set of held buttons and one aim, calling the same player_step the game window calls (docs/player.md, \"one path for a hand and a model\"). The first call turns on sim_play_begin, which snaps the play sandbox to the 2048 cell square he stands in so he stands on the running physics rather than a picture of it; after that it follows him when he leaves that square on its own.",
 "inputSchema":{"type":"object","properties":{
   "buttons":{"type":"array","items":{"type":"string","enum":["left","right","jump","run","dig","throw"]},"description":"Buttons held for every tick of this call."},
   "jump":{"type":"boolean","description":"Whether jump is a fresh press on the first tick of this call, for the jump edge. A held jump that was already pressed in an earlier call should be false. Default false."},
   "aim":{"type":"number","description":"Where the digger points, in degrees, held for every tick of this call. 0 is right, 90 is down, 180 is left, 270 is up, because y grows downward. The digger is a beam out of the centre of his mass, so this is the only thing that says which way it cuts. Default: the way he faces.","minimum":0,"maximum":360},
   "ticks":{"type":"integer","description":"Ticks to run (1 to 6000, which is 100 seconds). Default 1.","minimum":1,"maximum":6000}},
  "additionalProperties":false}}
]}`

mcp_call_tool :: proc(s: ^Sim, out: ^strings.Builder, id: json.Value, request: json.Object) {
	params, has_params := json_object_field(request, "params")
	if !has_params {
		mcp_write_error(out, id, -32602, "the call needs a params object")
		return
	}

	name := json_string_field(params, "name", "")
	arguments, _ := json_object_field(params, "arguments")

	switch name {
	case "world_status":
		mcp_write_tool_text(out, id, tool_world_status(s))
	case "list_materials":
		mcp_write_tool_text(out, id, tool_list_materials(s))
	case "list_biomes":
		mcp_write_tool_text(out, id, tool_list_biomes(s))
	case "biome_map_view":
		mcp_write_tool_text(out, id, tool_biome_map_view(s))
	case "biome_map_paint":
		text, failed := tool_biome_map_paint(s, arguments)
		mcp_write_tool_text(out, id, text, failed)
	case "biome_map_save":
		text, failed := tool_biome_map_save(s)
		mcp_write_tool_text(out, id, text, failed)
	case "tile_open":
		text, failed := tool_tile_open(s, arguments)
		mcp_write_tool_text(out, id, text, failed)
	case "tile_select":
		text, failed := tool_tile_select(s, arguments)
		mcp_write_tool_text(out, id, text, failed)
	case "tile_repair":
		text, failed := tool_tile_repair(s)
		mcp_write_tool_text(out, id, text, failed)
	case "tile_view":
		text, failed := tool_tile_view(s)
		mcp_write_tool_text(out, id, text, failed)
	case "tile_paint":
		text, failed := tool_tile_paint(s, arguments)
		mcp_write_tool_text(out, id, text, failed)
	case "tile_save":
		text, failed := tool_tile_save(s)
		mcp_write_tool_text(out, id, text, failed)
	case "sandbox_open":
		text, failed := tool_sandbox_open(s, arguments)
		mcp_write_tool_text(out, id, text, failed)
	case "enqueue_input":
		text, failed := tool_enqueue_input(s, arguments)
		mcp_write_tool_text(out, id, text, failed)
	case "tick":
		mcp_write_tool_text(out, id, tool_tick(s, arguments))
	case "observe":
		text, failed := tool_observe(s, arguments)
		mcp_write_tool_text(out, id, text, failed)
	case "queue_peek":
		mcp_write_tool_text(out, id, tool_queue_peek(s, arguments))
	case "player_status":
		mcp_write_tool_text(out, id, tool_player_status(s))
	case "player_move":
		text, failed := tool_player_move(s, arguments)
		mcp_write_tool_text(out, id, text, failed)
	case:
		mcp_write_tool_text(out, id, fmt.tprintf("unknown tool: %s", name), true)
	}
}

tool_world_status :: proc(s: ^Sim) -> string {
	b := strings.builder_make(context.temp_allocator)

	// Which world this is, because a seed is a world and one seed is a
	// different one. See docs/laboratory.md.
	fmt.sbprintf(
		&b, "%s, world seed %d\n",
		world_is_laboratory(s.world.biomes, s.world.seed) ? "the Laboratory" : "the ordinary world",
		s.world.seed,
	)

	m := s.world.biome_map
	fmt.sbprintf(
		&b, "biome map %dx%d pixels, one pixel is %d world cells\n",
		m.width, m.height, s.world.biomes.cells_per_pixel,
	)
	if editor_can_save(s) {
		strings.write_string(&b, "the map is connected, so it can be saved\n")
	} else {
		fmt.sbprintf(&b, "the map falls into %d separate regions, so a save is blocked\n", s.editor.component_count)
	}

	if s.tile_edit.open {
		fmt.sbprintf(
			&b, "tile set open: %s, tile %s (%s)\n",
			s.world.biomes.names[s.tile_edit.biome],
			tile_editor_describe(s),
			biome_tile_path(s.world.biomes, s.tile_edit.biome, tile_editor_tile(s)),
		)
		if !tile_editor_can_save(s) {
			fmt.sbprintf(
				&b, "the set disagrees with itself at cell (%d,%d), so a save is blocked\n",
				s.tile_edit.conflict.x, s.tile_edit.conflict.y,
			)
		}
	} else {
		strings.write_string(&b, "no tile set is open\n")
	}

	fmt.sbprintf(
		&b, "sandbox %dx%d at world (%d,%d), tick %d, seed %d\n",
		s.sandbox.width, s.sandbox.height, s.sandbox.origin_x, s.sandbox.origin_y,
		s.sandbox.tick, s.sandbox.seed,
	)
	fmt.sbprintf(&b, "input delay %d ticks\n", s.queue.delay)
	write_queue_line(&b, s)
	fmt.sbprintf(&b, "checksum 0x%016x\n", sandbox_checksum(&s.sandbox))
	write_census_line(&b, s)
	return strings.to_string(b)
}

tool_list_materials :: proc(s: ^Sim) -> string {
	b := strings.builder_make(context.temp_allocator)
	table := s.world.materials

	strings.write_string(&b, "idx glyph name    state    density fall hard flam force lum life decays_to burns_to\n")
	for material, i in table.materials {
		fmt.sbprintf(
			&b,
			"% 3d %c     %-7s %-8s % 7.2f % 4d % 4d % 4d % 5d % 3d % 4d %-9s %s\n",
			i,
			rune(table.glyphs[i]),
			table.names[i],
			material.state,
			material.density,
			material.fall_speed,
			material.hardness,
			material.flammability,
			material.force,
			material.luminosity,
			material.lifetime,
			table.names[table.decays_to[i]],
			table.names[table.burns_to[i]],
		)
	}
	strings.write_string(&b, "\nA denser material sinks through a lighter one that can flow.\n")
	strings.write_string(&b, "life is the ticks a cell lives before it turns into decays_to. -1 means it lasts.\n")
	strings.write_string(&b, "force is expulsive: the power and the reach of the blast it makes when it goes off.\n")
	strings.write_string(&b, "lum is the light it gives. A Phantom state has no physical interaction, so no cell holds one.\n")
	return strings.to_string(b)
}

tool_list_biomes :: proc(s: ^Sim) -> string {
	b := strings.builder_make(context.temp_allocator)
	table := s.world.biomes

	strings.write_string(&b, "id glyph name       key color  generator fill      tiles\n")
	for biome, i in table.biomes {
		set := biome.tile_base == TILE_NONE \
		? "-" \
		: fmt.tprintf("%s_*.png (%d)", table.tile_prefixes[i], wang_set_size(biome))
		fmt.sbprintf(
			&b,
			"% 2d %c     %-10s 0x%08X %-9v %-9s %s\n",
			i,
			rune(biome_glyph(s, Biome_Id(i))),
			table.names[i],
			biome.key_color,
			biome.generator,
			s.world.materials.names[biome.fill_0],
			set,
		)
	}
	fmt.sbprintf(&b, "\nOutside the map every region is %s.\n", table.names[table.off_map_biome])
	strings.write_string(&b, "A biome with generator = wang draws a lattice of tiles from its set. Open it with tile_open.\n")
	fmt.sbprintf(&b, "The world lays that lattice out from seed %d.\n", s.world.seed)
	return strings.to_string(b)
}

tool_biome_map_view :: proc(s: ^Sim) -> string {
	b := strings.builder_make(context.temp_allocator)
	m := s.world.biome_map

	fmt.sbprintf(
		&b, "biome map %dx%d, one pixel is %d world cells\n",
		m.width, m.height, s.world.biomes.cells_per_pixel,
	)
	fmt.sbprintf(
		&b, "world cell (0,0) is at map pixel (%d,%d)\n",
		s.world.biomes.origin_pixel_x, s.world.biomes.origin_pixel_y,
	)

	write_column_ruler(&b, 0, m.width, 1)

	seen: [256]bool
	empty_seen := false
	for y in i32(0) ..< m.height {
		fmt.sbprintf(&b, "% 4d ", y)
		for x in i32(0) ..< m.width {
			id := biome_map_at(m, x, y)
			if id == BIOME_EMPTY {
				empty_seen = true
				strings.write_byte(&b, '.')
			} else {
				seen[id] = true
				strings.write_byte(&b, biome_glyph(s, id))
			}
		}
		strings.write_string(&b, "\n")
	}

	strings.write_string(&b, "legend:")
	for present, i in seen {
		if !present do continue
		fmt.sbprintf(&b, " %c=%s", rune(biome_glyph(s, Biome_Id(i))), s.world.biomes.names[i])
	}
	if empty_seen {
		fmt.sbprintf(&b, " .=empty (generates as %s)", s.world.biomes.names[s.world.biomes.off_map_biome])
	}
	strings.write_string(&b, "\n")

	if editor_can_save(s) {
		strings.write_string(&b, "the map is connected, so it can be saved\n")
	} else {
		fmt.sbprintf(
			&b,
			"the map falls into %d separate regions, so a save is blocked until they are joined\n",
			s.editor.component_count,
		)
	}
	return strings.to_string(b)
}

tool_biome_map_paint :: proc(s: ^Sim, arguments: json.Object) -> (string, bool) {
	x := i32(json_int_field(arguments, "x", 0))
	y := i32(json_int_field(arguments, "y", 0))

	painted := 0

	if rows, has_rows := json_rows_field(arguments, "rows"); has_rows {
		for row, dy in rows {
			for i in 0 ..< len(row) {
				glyph := row[i]
				if glyph == ' ' || glyph == '.' do continue

				id, found := biome_by_glyph(s, glyph)
				if !found {
					return fmt.tprintf(
						"row %d holds %q, which is no biome glyph. Call list_biomes to see them.",
						dy, rune(glyph),
					), true
				}
				if editor_paint_pixel(s, x + i32(i), y + i32(dy), id) do painted += 1
			}
		}
	} else {
		name := json_string_field(arguments, "biome", "")
		if name == "" {
			return "give a biome name, or rows of biome glyphs. Call list_biomes to see them.", true
		}

		id := BIOME_EMPTY
		if name != "empty" {
			idx, found := find_biome_index(s.world.biomes, name)
			if !found {
				return fmt.tprintf("unknown biome %q. Call list_biomes to see the names.", name), true
			}
			id = Biome_Id(idx)
		}

		width := i32(max(json_int_field(arguments, "width", 1), 1))
		height := i32(max(json_int_field(arguments, "height", 1), 1))
		for py in y ..< y + height {
			for px in x ..< x + width {
				if editor_paint_pixel(s, px, py, id) do painted += 1
			}
		}
	}

	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "painted %d map pixels\n", painted)
	if editor_can_save(s) {
		strings.write_string(&b, "the map is connected, so it can be saved\n")
	} else {
		fmt.sbprintf(
			&b,
			"the map now falls into %d separate regions, so a save is blocked until they are joined\n",
			s.editor.component_count,
		)
	}
	if painted > 0 {
		strings.write_string(&b, "the world changed at once; call sandbox_open to bring the change into the physics\n")
	}
	return strings.to_string(b), false
}

tool_biome_map_save :: proc(s: ^Sim) -> (string, bool) {
	message, ok := editor_save_map(s)
	return message, !ok
}

tool_tile_open :: proc(s: ^Sim, arguments: json.Object) -> (string, bool) {
	name := json_string_field(arguments, "biome", "")
	idx, found := find_biome_index(s.world.biomes, name)
	if !found {
		return fmt.tprintf("unknown biome %q. Call list_biomes to see the names.", name), true
	}

	message, ok := tile_editor_begin(s, Biome_Id(idx))
	if !ok do return message, true

	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "%s\n", message)
	fmt.sbprintf(&b, "every tile is %dx%d cells\n", i32(TILE_SIZE), i32(TILE_SIZE))
	write_tile_set_lines(&b, s)
	return strings.to_string(b), false
}

@(private = "file")
write_tile_set_lines :: proc(b: ^strings.Builder, s: ^Sim) {
	e := &s.tile_edit
	biome := tile_editor_biome(s)

	fmt.sbprintf(
		b, "the %s set holds %d tiles: one for each of the %d ways to color four edges, times %d variants\n",
		s.world.biomes.names[e.biome], wang_set_size(biome), WANG_SIGNATURES, int(biome.variants),
	)
	fmt.sbprintf(b, "selected tile %s, file %s\n", tile_editor_describe(s), biome_tile_path(s.world.biomes, e.biome, tile_editor_tile(s)))
	fmt.sbprintf(
		b, "the world only puts two tiles side by side when they agree on the edge between them, so the outer %d cells of each side belong to the edge color, not to the tile\n",
		i32(WANG_SEAM),
	)
	strings.write_string(b, "paint there and every tile of the set that carries that color changes with it; a corner belongs to the whole set\n")

	if e.conflict.found {
		fmt.sbprintf(
			b, "the set disagrees with itself at cell (%d,%d), so a save is blocked; call tile_repair\n",
			e.conflict.x, e.conflict.y,
		)
	}
}

tool_tile_select :: proc(s: ^Sim, arguments: json.Object) -> (string, bool) {
	if !s.tile_edit.open {
		return "no tile set is open. Call tile_open with a biome name first.", true
	}

	sig := int(s.tile_edit.sig)
	if edges := json_string_field(arguments, "edges", ""); edges != "" {
		if len(edges) != 4 {
			return fmt.tprintf("edges is four digits, north east south west, and %q is not", edges), true
		}
		colors: [4]u8
		highest := u8('0') + u8(WANG_COLORS - 1)
		for i in 0 ..< 4 {
			digit := edges[i]
			if digit < u8('0') || digit > highest {
				return fmt.tprintf("an edge color is 0 to %d, and %q is not", WANG_COLORS - 1, rune(digit)), true
			}
			colors[i] = digit - u8('0')
		}
		sig = int(wang_signature(colors[0], colors[1], colors[2], colors[3]))
	}

	variant := int(json_int_field(arguments, "variant", i64(s.tile_edit.variant)))
	message, ok := tile_editor_select(s, sig, variant)
	if !ok do return message, true

	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "%s\n", message)
	fmt.sbprintf(&b, "file %s\n", biome_tile_path(s.world.biomes, s.tile_edit.biome, tile_editor_tile(s)))
	return strings.to_string(b), false
}

tool_tile_repair :: proc(s: ^Sim) -> (string, bool) {
	message, ok := tile_editor_normalize(s)
	return message, !ok
}

tool_tile_view :: proc(s: ^Sim) -> (string, bool) {
	if !s.tile_edit.open {
		return "no tile set is open. Call tile_open with a biome name first.", true
	}

	b := strings.builder_make(context.temp_allocator)
	write_tile_set_lines(&b, s)
	cells := tile_cells(s.world.tiles, tile_editor_tile(s))
	write_cell_map(&b, s, cells, TILE_SIZE, TILE_SIZE, 0, 0, 1)
	return strings.to_string(b), false
}

tool_tile_paint :: proc(s: ^Sim, arguments: json.Object) -> (string, bool) {
	if !s.tile_edit.open {
		return "no tile set is open. Call tile_open with a biome name first.", true
	}

	x := i32(json_int_field(arguments, "x", 0))
	y := i32(json_int_field(arguments, "y", 0))

	painted := 0
	shared := 0

	if rows, has_rows := json_rows_field(arguments, "rows"); has_rows {
		for row, dy in rows {
			for i in 0 ..< len(row) {
				glyph := row[i]
				if glyph == ' ' do continue

				material, found := material_by_glyph(s, glyph)
				if !found {
					return fmt.tprintf(
						"row %d holds %q, which is no material glyph. Call list_materials to see them.",
						dy, rune(glyph),
					), true
				}
				if tile_editor_paint_cell(s, x + i32(i), y + i32(dy), material) {
					painted += 1
					if wang_band(x + i32(i), y + i32(dy)) != .Inside do shared += 1
				}
			}
		}
	} else {
		name := json_string_field(arguments, "material", "")
		if name == "" {
			return "give a material name, or rows of material glyphs. Call list_materials to see them.", true
		}
		idx, found := find_material_index(s.world.materials, name)
		if !found {
			return fmt.tprintf("unknown material %q. Call list_materials to see the names.", name), true
		}

		width := i32(max(json_int_field(arguments, "width", 1), 1))
		height := i32(max(json_int_field(arguments, "height", 1), 1))
		for py in y ..< y + height {
			for px in x ..< x + width {
				if tile_editor_paint_cell(s, px, py, Cell(idx)) {
					painted += 1
					if wang_band(px, py) != .Inside do shared += 1
				}
			}
		}
	}

	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "painted %d tile cells\n", painted)
	if shared > 0 {
		fmt.sbprintf(
			&b,
			"%d of them sat in a border band, so they went into every tile of the set that carries that edge color\n",
			shared,
		)
	}
	if painted > 0 {
		fmt.sbprintf(
			&b,
			"every %s region in the world changed at once; call tile_save to write the files, or sandbox_open to bring the change into the physics\n",
			s.world.biomes.names[s.tile_edit.biome],
		)
	}
	return strings.to_string(b), false
}

tool_tile_save :: proc(s: ^Sim) -> (string, bool) {
	message, ok := tile_editor_save_tiles(s)
	return message, !ok
}

tool_sandbox_open :: proc(s: ^Sim, arguments: json.Object) -> (string, bool) {
	width := i32(clamp(json_int_field(arguments, "width", i64(s.sandbox.width)), 1, SANDBOX_MAX_WIDTH))
	height := i32(clamp(json_int_field(arguments, "height", i64(s.sandbox.height)), 1, SANDBOX_MAX_HEIGHT))
	seed := u64(json_int_field(arguments, "seed", 1))
	delay := u8(clamp(json_int_field(arguments, "input_delay", SANDBOX_DEFAULT_DELAY), 0, INPUT_DELAY_MAX))

	origin_x := i32(json_int_field(arguments, "x", i64(s.sandbox.origin_x)))
	origin_y := i32(json_int_field(arguments, "y", i64(s.sandbox.origin_y)))

	found_biome := ""
	if name := json_string_field(arguments, "biome", ""); name != "" {
		idx, found := find_biome_index(s.world.biomes, name)
		if !found {
			return fmt.tprintf("unknown biome %q. Call list_biomes to see the names.", name), true
		}
		px, py, painted := biome_first_pixel(s, Biome_Id(idx))
		if !painted {
			return fmt.tprintf(
				"%s is not painted on the map this seed opens; the galleries want seed=0x1AB (see [Laboratory] in %s)",
				name, BIOMES_PATH,
			), true
		}
		cpp := s.world.biomes.cells_per_pixel
		origin_x = (px - s.world.biomes.origin_pixel_x) * cpp
		origin_y = (py - s.world.biomes.origin_pixel_y) * cpp
		found_biome = name
	}

	if err := sim_open_sandbox(s, width, height, origin_x, origin_y, seed, delay); err != .None {
		return fmt.tprintf("the sandbox could not be opened: %v", err), true
	}

	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "sandbox %dx%d filled from world (%d,%d)", width, height, origin_x, origin_y)
	if found_biome != "" do fmt.sbprintf(&b, ", the first %s region", found_biome)
	strings.write_string(&b, "\n")
	fmt.sbprintf(
		&b, "seed %d, input delay %d ticks, tick %d, the queue is empty\n",
		seed, delay, s.sandbox.tick,
	)
	fmt.sbprintf(&b, "checksum 0x%016x\n", sandbox_checksum(&s.sandbox))
	write_census_line(&b, s)
	return strings.to_string(b), false
}

tool_enqueue_input :: proc(s: ^Sim, arguments: json.Object) -> (string, bool) {
	kind_name := json_string_field(arguments, "kind", "")
	kind, kind_ok := parse_command_kind(kind_name)
	if !kind_ok {
		return fmt.tprintf("unknown kind %q. Use spawn, erase, ignite, explode, dig, move, or noop.", kind_name), true
	}

	command := Input_Command {
		kind   = kind,
		x      = i32(json_int_field(arguments, "x", 0)),
		y      = i32(json_int_field(arguments, "y", 0)),
		radius = u16(clamp(json_int_field(arguments, "radius", 0), 0, 512)),
		source = u8(clamp(json_int_field(arguments, "source", 0), 0, 255)),
	}

	material_name := json_string_field(arguments, "material", "")
	if kind == .Spawn {
		if material_name == "" {
			return "spawn needs a material name. Call list_materials to see the names.", true
		}
		index, found := find_material_index(s.world.materials, material_name)
		if !found {
			return fmt.tprintf("unknown material %q. Call list_materials to see the names.", material_name), true
		}
		if material_is_phantom(s.world.materials.materials[index]) {
			return fmt.tprintf(
				"%s has no physical interaction, so no cell can hold it. It is a light the world carries, not matter.",
				material_name,
			), true
		}
		command.material = u16(index)
	}

	if kind == .Explode || kind == .Dig {
		if !json_has_field(arguments, "power") {
			return fmt.tprintf("%s needs a power (0 to 255). Explode: energy per ray. Dig: hardness removed; rock is 8.", kind_name), true
		}
		command.material = u16(clamp(json_int_field(arguments, "power", 0), 0, 255))
	}

	if kind == .Move {
		buttons, _ := json_rows_field(arguments, "buttons")
		held, bad_held, held_ok := parse_player_buttons(buttons)
		if !held_ok {
			return fmt.tprintf("%q is not a button. Use left, right, jump, run, dig, or throw.", bad_held), true
		}
		pressed, _ := json_rows_field(arguments, "pressed")
		edge, bad_pressed, pressed_ok := parse_player_buttons(pressed)
		if !pressed_ok {
			return fmt.tprintf("%q is not a button. Use left, right, jump, run, dig, or throw.", bad_pressed), true
		}
		command.buttons = held
		command.pressed = edge
		// x field carries aim for Move; must match input_queue.odin
		command.x = i32(parse_player_aim(s, arguments))
	}

	at_tick := i64(-1)
	if json_has_field(arguments, "tick") {
		at_tick = json_int_field(arguments, "tick", -1)
	}

	out, status := sim_enqueue(s, command, at_tick)

	switch status {
	case .Bad_Source:
		return fmt.tprintf("source must be 0 to %d", INPUT_SOURCES-1), true
	case .Too_Far:
		return fmt.tprintf(
			"tick %d is too far ahead. The queue holds ticks %d to %d.",
			at_tick, s.sandbox.tick, s.sandbox.tick + INPUT_SLOT_COUNT - 1,
		), true
	case .Slot_Full:
		return fmt.tprintf(
			"tick %d already holds %d commands, which is the limit. Use another tick.",
			at_tick, INPUT_PER_SLOT,
		), true
	case .Accepted, .Late:
	}

	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "queued %v", out.kind)
	switch kind {
	case .Spawn:
		fmt.sbprintf(&b, " %s at (%d,%d) radius %d\n", s.world.materials.names[out.material], out.x, out.y, out.radius)
	case .Explode, .Dig:
		fmt.sbprintf(&b, " power %d at (%d,%d) radius %d\n", out.material, out.x, out.y, out.radius)
	case .Move:
		fmt.sbprintf(&b, " buttons %v pressed %v aim %d\n", out.buttons, out.pressed, u8(out.x))
	case .Erase, .Ignite, .Noop:
		fmt.sbprintf(&b, " at (%d,%d) radius %d\n", out.x, out.y, out.radius)
	}
	fmt.sbprintf(
		&b, "runs on tick %d (now %d, delay %d), source %d, seq %d\n",
		out.tick, s.sandbox.tick, s.queue.delay, out.source, out.seq,
	)

	if status == .Late {
		fmt.sbprintf(&b, "the tick you asked for had already run, so the command moved to tick %d\n", out.tick)
	}
	if out.tick > s.sandbox.tick {
		fmt.sbprintf(&b, "call tick with count %d to reach it\n", out.tick - s.sandbox.tick + 1)
	}
	write_queue_line(&b, s)
	return strings.to_string(b), false
}

tool_tick :: proc(s: ^Sim, arguments: json.Object) -> string {
	count := int(clamp(json_int_field(arguments, "count", 1), 1, 100000))

	start := s.sandbox.tick
	applied := sim_run(s, count)

	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "ran %d ticks: %d -> %d\n", count, start, s.sandbox.tick)
	fmt.sbprintf(&b, "applied %d commands\n", applied)
	write_queue_line(&b, s)
	fmt.sbprintf(&b, "checksum 0x%016x\n", sandbox_checksum(&s.sandbox))
	write_census_line(&b, s)
	return strings.to_string(b)
}

tool_observe :: proc(s: ^Sim, arguments: json.Object) -> (string, bool) {
	if json_string_field(arguments, "source", "sandbox") == "world" {
		return observe_world(s, arguments)
	}
	return observe_sandbox(s, arguments)
}

@(private = "file")
observe_sandbox :: proc(s: ^Sim, arguments: json.Object) -> (string, bool) {
	sb := &s.sandbox
	ox := i32(clamp(json_int_field(arguments, "x", 0), 0, i64(sb.width-1)))
	oy := i32(clamp(json_int_field(arguments, "y", 0), 0, i64(sb.height-1)))
	sample := i32(clamp(json_int_field(arguments, "sample", 1), 1, 64))

	width := i32(clamp(json_int_field(arguments, "width", i64(sb.width)), 1, i64(sb.width-ox)))
	height := i32(clamp(json_int_field(arguments, "height", i64(sb.height)), 1, i64(sb.height-oy)))

	columns := (width + sample - 1) / sample
	rows := (height + sample - 1) / sample
	if message, ok := check_map_size(columns, rows); !ok do return message, true

	view := make([]Cell, int(columns) * int(rows), context.temp_allocator)
	for r in 0 ..< rows {
		for c in 0 ..< columns {
			view[int(r)*int(columns) + int(c)] = sample_sandbox(s, ox + c*sample, oy + r*sample, sample)
		}
	}

	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(
		&b, "sandbox at tick %d, region (%d,%d) %dx%d of %dx%d",
		sb.tick, ox, oy, width, height, sb.width, sb.height,
	)
	if sample > 1 do fmt.sbprintf(&b, ", one character per %dx%d cells", sample, sample)
	fmt.sbprintf(&b, "\nthe sandbox sits at world (%d,%d)\n", sb.origin_x, sb.origin_y)

	write_cell_map(&b, s, view, columns, rows, ox, oy, sample)
	return strings.to_string(b), false
}

@(private = "file")
observe_world :: proc(s: ^Sim, arguments: json.Object) -> (string, bool) {
	step := i32(clamp(json_int_field(arguments, "step", 1), 1, 4096))
	ox := i32(json_int_field(arguments, "x", i64(s.sandbox.origin_x)))
	oy := i32(json_int_field(arguments, "y", i64(s.sandbox.origin_y)))
	columns := i32(clamp(json_int_field(arguments, "width", i64(s.sandbox.width)), 1, 4096))
	rows := i32(clamp(json_int_field(arguments, "height", i64(s.sandbox.height)), 1, 4096))

	if message, ok := check_map_size(columns, rows); !ok do return message, true

	view := make([]Cell, int(columns) * int(rows), context.temp_allocator)
	generate(s.world, World_View{x = ox, y = oy, w = columns, h = rows, step = step}, view)

	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(
		&b, "world as the generator makes it, from (%d,%d), %dx%d characters",
		ox, oy, columns, rows,
	)
	if step > 1 do fmt.sbprintf(&b, ", one character per %d world cells", step)
	strings.write_string(&b, "\n")

	fmt.sbprintf(
		&b, "top left is %s, bottom right is %s\n",
		s.world.biomes.names[world_biome_at(s.world, ox, oy)],
		s.world.biomes.names[world_biome_at(s.world, ox + (columns-1)*step, oy + (rows-1)*step)],
	)

	write_cell_map(&b, s, view, columns, rows, ox, oy, step)
	return strings.to_string(b), false
}

tool_queue_peek :: proc(s: ^Sim, arguments: json.Object) -> string {
	ticks := int(clamp(json_int_field(arguments, "ticks", 16), 1, INPUT_SLOT_COUNT))

	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "tick %d, input delay %d ticks\n", s.sandbox.tick, s.queue.delay)

	total := 0
	for offset in 0 ..< ticks {
		when_ := s.sandbox.tick + u64(offset)
		waiting := input_queue_peek(&s.queue, when_)
		if len(waiting) == 0 do continue

		fmt.sbprintf(&b, "tick %d:\n", when_)
		for command in waiting {
			fmt.sbprintf(&b, "  %v", command.kind)
			if command.kind == .Spawn do fmt.sbprintf(&b, " %s", s.world.materials.names[command.material])
			fmt.sbprintf(
				&b, " at (%d,%d) radius %d, source %d, seq %d\n",
				command.x, command.y, command.radius, command.source, command.seq,
			)
			total += 1
		}
	}

	if total == 0 do fmt.sbprintf(&b, "no commands wait in the next %d ticks\n", ticks)
	write_queue_line(&b, s)
	return strings.to_string(b)
}

tool_player_status :: proc(s: ^Sim) -> string {
	p := s.player
	t := Terrain{world = &s.world, sandbox = s.follow_player ? &s.sandbox : nil}

	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "wizard at (%.1f,%.1f), facing %s\n", p.x, p.y, p.facing > 0 ? "right" : "left")

	if p.on_ground {
		cell := terrain_cell_at(t, i32(math.floor(p.x)), i32(math.floor(p.y)))
		fmt.sbprintf(&b, "on the ground, standing on %s\n", s.world.materials.names[cell])
	} else {
		strings.write_string(&b, "in the air\n")
	}

	fmt.sbprintf(&b, "velocity (%.1f,%.1f) cells per second\n", p.vx, p.vy)
	fmt.sbprintf(&b, "fuel %.2f of %.2f\n", p.fuel, f32(PLAYER_FUEL_MAX))

	if s.follow_player {
		fmt.sbprintf(&b, "the play sandbox is following him, at world (%d,%d)\n", s.sandbox.origin_x, s.sandbox.origin_y)
	} else {
		strings.write_string(&b, "the play sandbox is not following him yet; call player_move to start\n")
	}
	return strings.to_string(b)
}

tool_player_move :: proc(s: ^Sim, arguments: json.Object) -> (string, bool) {
	names, _ := json_rows_field(arguments, "buttons")
	held, bad, buttons_ok := parse_player_buttons(names)
	if !buttons_ok {
		return fmt.tprintf("%q is not a button. Use left, right, jump, run, dig, or throw.", bad), true
	}

	ticks := int(clamp(json_int_field(arguments, "ticks", 1), 1, 6000))
	jump := json_bool_field(arguments, "jump", false)
	aim := parse_player_aim(s, arguments)

	sim_play_begin(s)
	for i in 0 ..< ticks {
		sim_step_player(s, held, i == 0 && jump, aim)
	}

	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "ran %d ticks holding %v, aim %d\n", ticks, held, aim)
	fmt.sbprintf(&b, "wizard now at (%.1f,%.1f), on_ground %v\n", s.player.x, s.player.y, s.player.on_ground)
	fmt.sbprintf(&b, "the play sandbox is at world (%d,%d)\n", s.sandbox.origin_x, s.sandbox.origin_y)
	return strings.to_string(b), false
}

parse_command_kind :: proc(name: string) -> (Command_Kind, bool) {
	switch name {
	case "noop":    return .Noop, true
	case "spawn":   return .Spawn, true
	case "erase":   return .Erase, true
	case "ignite":  return .Ignite, true
	case "explode": return .Explode, true
	case "dig":     return .Dig, true
	case "move":    return .Move, true
	}
	return .Noop, false
}

parse_player_aim :: proc(s: ^Sim, arguments: json.Object) -> u8 {
	if !json_has_field(arguments, "aim") {
		return s.player.facing < 0 ? PLAYER_AIM_LEFT : PLAYER_AIM_RIGHT
	}
	degrees := json_number_field(arguments, "aim", 0)
	return u8(i32(math.round(degrees / 360 * 256)) & 255)
}

parse_player_buttons :: proc(names: []string) -> (held: Player_Input, bad: string, ok: bool) {
	for name in names {
		switch name {
		case "left":  held += {.Left}
		case "right": held += {.Right}
		case "jump":  held += {.Jump}
		case "run":   held += {.Run}
		case "dig":   held += {.Dig}
		case "throw": held += {.Throw}
		case:
			return {}, name, false
		}
	}
	return held, "", true
}

check_map_size :: proc(columns, rows: i32) -> (string, bool) {
	if int(columns) * int(rows) <= MCP_MAX_MAP_CELLS do return "", true
	return fmt.tprintf(
		"the region holds %d characters, and the limit is %d. Ask for a smaller region, or raise sample or step.",
		int(columns)*int(rows), MCP_MAX_MAP_CELLS,
	), false
}

// A biome glyph is the first letter of its name. A name whose letter an
// earlier biome already took falls back to a digit, counted over the
// biomes that had to fall back rather than over the whole table, so
// the eleventh biome and the thirteenth do not both land on '?'.
biome_glyph :: proc(s: ^Sim, id: Biome_Id) -> u8 {
	names := s.world.biomes.names
	if int(id) >= len(names) || len(names[id]) == 0 do return '?'

	letter_taken :: proc(names: []string, id: int) -> bool {
		wanted := upper_byte(names[id][0])
		for i in 0 ..< id {
			if len(names[i]) > 0 && upper_byte(names[i][0]) == wanted do return true
		}
		return false
	}

	if !letter_taken(names, int(id)) do return upper_byte(names[id][0])

	nth := 0
	for i in 0 ..< int(id) {
		if len(names[i]) > 0 && letter_taken(names, i) do nth += 1
	}
	return nth < 10 ? byte('0') + byte(nth) : '?'
}

biome_by_glyph :: proc(s: ^Sim, glyph: u8) -> (Biome_Id, bool) {
	for _, i in s.world.biomes.biomes {
		if biome_glyph(s, Biome_Id(i)) == glyph do return Biome_Id(i), true
	}
	return BIOME_EMPTY, false
}

material_by_glyph :: proc(s: ^Sim, glyph: u8) -> (Cell, bool) {
	for g, i in s.world.materials.glyphs {
		if g == glyph do return Cell(i), true
	}
	return MATERIAL_AIR, false
}

upper_byte :: proc(c: u8) -> u8 {
	return c >= 'a' && c <= 'z' ? c - 32 : c
}

biome_first_pixel :: proc(s: ^Sim, id: Biome_Id) -> (px: i32, py: i32, found: bool) {
	m := s.world.biome_map
	for y in i32(0) ..< m.height {
		for x in i32(0) ..< m.width {
			if biome_map_at(m, x, y) == id do return x, y, true
		}
	}
	return 0, 0, false
}

sample_sandbox :: proc(s: ^Sim, x, y, sample: i32) -> Cell {
	if sample == 1 do return sandbox_cell(&s.sandbox, x, y)

	for dy in 0 ..< sample {
		for dx in 0 ..< sample {
			material := sandbox_cell(&s.sandbox, x+dx, y+dy)
			if material != MATERIAL_AIR do return material
		}
	}
	return MATERIAL_AIR
}

write_column_ruler :: proc(b: ^strings.Builder, origin, columns, step: i32) {
	strings.write_string(b, "     ")
	for c in 0 ..< columns {
		x := origin + c*step
		strings.write_byte(b, x % 10 == 0 ? byte('0') + byte(abs(x/10) % 10) : ' ')
	}
	strings.write_string(b, "\n     ")
	for c in 0 ..< columns {
		x := origin + c*step
		strings.write_byte(b, byte('0') + byte(abs(x) % 10))
	}
	strings.write_string(b, "\n")
}

write_cell_map :: proc(
	b: ^strings.Builder,
	s: ^Sim,
	cells: []Cell,
	columns, rows: i32,
	origin_x, origin_y, step: i32,
) {
	glyphs := s.world.materials.glyphs
	names := s.world.materials.names

	write_column_ruler(b, origin_x, columns, step)

	seen: [256]bool
	for r in 0 ..< rows {
		fmt.sbprintf(b, "% 4d ", origin_y + r*step)
		for c in 0 ..< columns {
			material := cells[int(r)*int(columns) + int(c)]
			if int(material) < len(glyphs) {
				seen[material] = true
				strings.write_byte(b, glyphs[material])
			} else {
				strings.write_byte(b, '?')
			}
		}
		strings.write_string(b, "\n")
	}

	strings.write_string(b, "legend:")
	for present, i in seen {
		if !present do continue
		fmt.sbprintf(b, " %c=%s", rune(glyphs[i]), names[i])
	}
	strings.write_string(b, "\n")
}

write_queue_line :: proc(b: ^strings.Builder, s: ^Sim) {
	fmt.sbprintf(
		b,
		"queue: %d waiting, %d accepted, %d late, %d rejected, %d applied\n",
		input_queue_depth(&s.queue), s.queue.accepted, s.queue.late, s.queue.rejected, s.queue.applied,
	)
}

write_census_line :: proc(b: ^strings.Builder, s: ^Sim) {
	counts := make([]int, len(s.world.materials.materials), context.temp_allocator)
	sandbox_census(&s.sandbox, counts)

	strings.write_string(b, "cells:")
	for count, i in counts {
		if count == 0 do continue
		fmt.sbprintf(b, " %s %d", s.world.materials.names[i], count)
	}
	strings.write_string(b, "\n")
}

@(private = "file")
tool_sim :: proc(t: ^testing.T) -> Sim {
	s: Sim
	err := sim_load(&s)
	testing.expect(t, err == .None, "the simulation must load")
	return s
}

@(private = "file")
arguments_of :: proc(t: ^testing.T, text: string) -> json.Object {
	value, err := json.parse_string(text, .JSON, true, context.temp_allocator)
	testing.expect(t, err == .None, "the test arguments must parse")
	object, ok := value.(json.Object)
	testing.expect(t, ok)
	return object
}

@(private = "file")
select_arguments :: proc(t: ^testing.T, sig: Wang_Signature, variant: int) -> json.Object {
	text := strings.concatenate(
		{
			`{"edges":"`,
			fmt.tprintf("%d%d%d%d", wang_north(sig), wang_east(sig), wang_south(sig), wang_west(sig)),
			`","variant":`,
			fmt.tprintf("%d", variant),
			`}`,
		},
		context.temp_allocator,
	)
	return arguments_of(t, text)
}

@(test)
test_tool_list_is_valid_json :: proc(t: ^testing.T) {
	value, err := json.parse_string(MCP_TOOLS_JSON, .JSON, true, context.temp_allocator)
	testing.expect(t, err == .None, "the tool list must be valid JSON")

	object, ok := value.(json.Object)
	testing.expect(t, ok)

	tools, has_tools := object["tools"]
	testing.expect(t, has_tools, "the list must hold a tools array")

	array, is_array := tools.(json.Array)
	testing.expect(t, is_array)
	testing.expect(t, len(array) == 19, "nineteen tools must be listed")

	for entry in array {
		tool, tool_ok := entry.(json.Object)
		testing.expect(t, tool_ok)
		testing.expect(t, json_string_field(tool, "name", "") != "", "a tool needs a name")
		testing.expect(t, json_string_field(tool, "description", "") != "", "a tool needs a description")
		_, has_schema := json_object_field(tool, "inputSchema")
		testing.expect(t, has_schema, "a tool needs an input schema")
	}
}

@(test)
test_tool_list_fits_on_one_line :: proc(t: ^testing.T) {
	listing := MCP_TOOLS_JSON
	folded := strings.builder_make(context.temp_allocator)
	for i in 0 ..< len(listing) {
		if listing[i] == '\n' do continue
		strings.write_byte(&folded, listing[i])
	}

	text := strings.to_string(folded)
	testing.expect(t, !strings.contains(text, "\n"), "the folded list must hold no newline")

	_, err := json.parse_string(text, .JSON, true, context.temp_allocator)
	testing.expect(t, err == .None, "the folded list must still be valid JSON")
}

@(test)
test_biome_glyphs_round_trip :: proc(t: ^testing.T) {
	s := tool_sim(t)
	defer sim_unload(&s)

	for _, i in s.world.biomes.biomes {
		glyph := biome_glyph(&s, Biome_Id(i))
		testing.expectf(t, glyph != '.', "%s must not take the empty glyph", s.world.biomes.names[i])

		id, found := biome_by_glyph(&s, glyph)
		testing.expectf(
			t, found && int(id) == i,
			"%s must round trip through its glyph", s.world.biomes.names[i],
		)
	}
}

@(test)
test_biome_map_paint_and_view :: proc(t: ^testing.T) {
	s := tool_sim(t)
	defer sim_unload(&s)

	text, failed := tool_biome_map_paint(&s, arguments_of(t, `{"x":0,"y":0,"width":2,"height":2,"biome":"Lake"}`))
	testing.expect(t, !failed, "a good paint must be accepted")
	testing.expect(t, strings.contains(text, "painted 4 map pixels"))

	lake, _ := find_biome_index(s.world.biomes, "Lake")
	testing.expect(t, int(biome_map_at(s.world.biome_map, 0, 0)) == lake, "the map must hold the paint")
	testing.expect(t, int(biome_map_at(s.world.biome_map, 1, 1)) == lake)

	view := tool_biome_map_view(&s)
	testing.expect(t, strings.contains(view, "=Lake"), "the legend must name what is on the map")
}

@(test)
test_biome_map_paint_takes_a_picture :: proc(t: ^testing.T) {
	s := tool_sim(t)
	defer sim_unload(&s)

	glyph := [2]u8{biome_glyph(&s, Biome_Id(0)), biome_glyph(&s, Biome_Id(0))}
	row := string(glyph[:])
	rows := strings.concatenate(
		{`{"x":2,"y":2,"rows":["`, row, `","`, row, `"]}`},
		context.temp_allocator,
	)

	text, failed := tool_biome_map_paint(&s, arguments_of(t, rows))
	testing.expect(t, !failed)
	testing.expect(t, strings.contains(text, "painted"))
	testing.expect(t, biome_map_at(s.world.biome_map, 2, 2) == 0, "the picture must land at x,y")
	testing.expect(t, biome_map_at(s.world.biome_map, 3, 3) == 0)
}

@(test)
test_biome_map_paint_rejects_what_it_cannot_read :: proc(t: ^testing.T) {
	s := tool_sim(t)
	defer sim_unload(&s)

	_, failed := tool_biome_map_paint(&s, arguments_of(t, `{"x":0,"y":0,"rows":["ZZ"]}`))
	testing.expect(t, failed, "an unknown glyph must fail")

	_, unknown := tool_biome_map_paint(&s, arguments_of(t, `{"x":0,"y":0,"biome":"Atlantis"}`))
	testing.expect(t, unknown, "an unknown biome must fail")
}

@(test)
test_biome_map_save_is_blocked_when_the_map_is_cut_in_two :: proc(t: ^testing.T) {
	s := tool_sim(t)
	defer sim_unload(&s)

	m := s.world.biome_map
	for y in i32(0) ..< m.height {
		for x in i32(0) ..< m.width do editor_erase_pixel(&s, x, y)
	}
	editor_paint_pixel(&s, 0, 0, 0)
	editor_paint_pixel(&s, 5, 5, 0)

	text, failed := tool_biome_map_save(&s)
	testing.expect(t, failed, "a cut map must not save")
	testing.expect(t, strings.contains(text, "separate regions"), "the reply must say why")
}

@(test)
test_tile_tools_need_an_open_set :: proc(t: ^testing.T) {
	s := tool_sim(t)
	defer sim_unload(&s)

	_, view_failed := tool_tile_view(&s)
	testing.expect(t, view_failed, "there is no set open yet")

	_, paint_failed := tool_tile_paint(&s, arguments_of(t, `{"x":0,"y":0,"material":"Gold"}`))
	testing.expect(t, paint_failed, "painting needs an open set")

	_, select_failed := tool_tile_select(&s, arguments_of(t, `{"edges":"0000"}`))
	testing.expect(t, select_failed, "choosing a tile needs an open set")
}

@(test)
test_tile_open_refuses_a_flat_biome :: proc(t: ^testing.T) {
	s := tool_sim(t)
	defer sim_unload(&s)

	text, failed := tool_tile_open(&s, arguments_of(t, `{"biome":"Sky"}`))
	testing.expect(t, failed, "a flat biome has no tiles")
	testing.expect(t, strings.contains(text, "generator = wang"), "the reply must say how to give it some")
}

@(test)
test_tile_open_select_paint_and_view :: proc(t: ^testing.T) {
	s := tool_sim(t)
	defer sim_unload(&s)

	opened, failed := tool_tile_open(&s, arguments_of(t, `{"biome":"Coalmine"}`))
	testing.expect(t, !failed, "Coalmine owns a set")
	testing.expect(t, strings.contains(opened, "Coalmine"))
	testing.expect(t, s.tile_edit.open)

	chosen, select_failed := tool_tile_select(&s, arguments_of(t, `{"edges":"1010"}`))
	testing.expect(t, !select_failed)
	testing.expect(t, strings.contains(chosen, "coalmine_1010_0.png"), "the reply must name the file")
	testing.expect(t, wang_north(s.tile_edit.sig) == 1 && wang_east(s.tile_edit.sig) == 0)
	testing.expect(t, wang_south(s.tile_edit.sig) == 1 && wang_west(s.tile_edit.sig) == 0)

	tool_tile_paint(&s, arguments_of(t, `{"x":20,"y":20,"width":4,"height":4,"material":"Rock"}`))
	text, paint_failed := tool_tile_paint(&s, arguments_of(t, `{"x":20,"y":20,"width":4,"height":4,"material":"Gold"}`))
	testing.expect(t, !paint_failed)
	testing.expect(t, strings.contains(text, "painted 16 tile cells"))

	gold, _ := find_material_index(s.world.materials, "Gold")
	tile := tile_editor_tile(&s)
	testing.expect(t, int(tile_at(s.world.tiles, tile, 20, 20)) == gold, "the tile must hold the paint")
	testing.expect(t, int(tile_at(s.world.tiles, tile, 23, 23)) == gold)

	view, view_failed := tool_tile_view(&s)
	testing.expect(t, !view_failed)
	testing.expect(t, strings.contains(view, "=Gold"), "the legend must name the paint")
}

@(test)
test_tile_select_refuses_a_bad_name :: proc(t: ^testing.T) {
	s := tool_sim(t)
	defer sim_unload(&s)
	tool_tile_open(&s, arguments_of(t, `{"biome":"Coalmine"}`))

	_, short := tool_tile_select(&s, arguments_of(t, `{"edges":"01"}`))
	testing.expect(t, short, "a tile is named by four edges")

	_, bad := tool_tile_select(&s, arguments_of(t, `{"edges":"0192"}`))
	testing.expect(t, bad, "an edge color that does not exist is a mistake")

	_, no_variant := tool_tile_select(&s, arguments_of(t, `{"edges":"0000","variant":9}`))
	testing.expect(t, no_variant, "a variant nobody drew is a mistake")
}

@(test)
test_a_seam_paint_reaches_every_tile_with_that_edge :: proc(t: ^testing.T) {
	s := tool_sim(t)
	defer sim_unload(&s)
	tool_tile_open(&s, arguments_of(t, `{"biome":"Coalmine"}`))
	tool_tile_select(&s, arguments_of(t, `{"edges":"0001"}`))

	text, failed := tool_tile_paint(&s, arguments_of(t, `{"x":0,"y":32,"material":"Gold"}`))
	testing.expect(t, !failed)
	testing.expect(t, strings.contains(text, "border band"), "the reply must say the stroke was shared")

	gold, _ := find_material_index(s.world.materials, "Gold")
	b := tile_editor_biome(&s)
	for sig in 0 ..< WANG_SIGNATURES {
		for v in 0 ..< int(b.variants) {
			tile := wang_tile_id(b, Wang_Signature(sig), v)
			holds := int(tile_at(s.world.tiles, tile, 0, 32)) == gold
			testing.expectf(
				t,
				holds == (wang_west(Wang_Signature(sig)) == 1),
				"tile %d has west edge %d and %v the paint",
				sig,
				wang_west(Wang_Signature(sig)),
				holds ? "holds" : "does not hold",
			)
		}
	}

	testing.expect(t, tile_editor_can_save(&s))
}

@(test)
test_the_save_gate_catches_a_broken_seam :: proc(t: ^testing.T) {
	s := tool_sim(t)
	defer sim_unload(&s)
	tool_tile_open(&s, arguments_of(t, `{"biome":"Coalmine"}`))

	b := tile_editor_biome(&s)
	gold, _ := find_material_index(s.world.materials, "Gold")
	tile_set_cell(s.world.tiles, wang_tile_id(b, wang_signature(1, 1, 1, 1), 0), 0, 32, Cell(gold))
	tile_editor_refresh(&s)

	testing.expect(t, !tile_editor_can_save(&s), "the set no longer agrees with itself")
	text, failed := tool_tile_save(&s)
	testing.expect(t, failed, "a broken seam must not save")
	testing.expect(t, strings.contains(text, "disagree"), "the reply must say why")

	repaired, repair_failed := tool_tile_repair(&s)
	testing.expect(t, !repair_failed, repaired)
	testing.expect(t, tile_editor_can_save(&s), "the repair must open the gate")
}

@(test)
test_tile_paint_takes_a_picture :: proc(t: ^testing.T) {
	s := tool_sim(t)
	defer sim_unload(&s)
	tool_tile_open(&s, arguments_of(t, `{"biome":"Coalmine"}`))

	tile := tile_editor_tile(&s)
	before := tile_at(s.world.tiles, tile, 21, 20)
	_, failed := tool_tile_paint(&s, arguments_of(t, `{"x":20,"y":20,"rows":["G G","GGG"]}`))
	testing.expect(t, !failed)

	gold, _ := find_material_index(s.world.materials, "Gold")
	testing.expect(t, int(tile_at(s.world.tiles, tile, 20, 20)) == gold)
	testing.expect(t, tile_at(s.world.tiles, tile, 21, 20) == before, "a space must leave the cell alone")
	testing.expect(t, int(tile_at(s.world.tiles, tile, 22, 20)) == gold)
	testing.expect(t, int(tile_at(s.world.tiles, tile, 21, 21)) == gold)
}

@(test)
test_a_tile_paint_reaches_the_world_and_the_sandbox :: proc(t: ^testing.T) {
	s := tool_sim(t)
	defer sim_unload(&s)

	tool_tile_open(&s, arguments_of(t, `{"biome":"Coalmine"}`))

	b := tile_editor_biome(&s)
	for sig in 0 ..< WANG_SIGNATURES {
		for v in 0 ..< int(b.variants) {
			tool_tile_select(&s, select_arguments(t, Wang_Signature(sig), v))
			tool_tile_paint(&s, arguments_of(t, `{"x":0,"y":0,"width":64,"height":64,"material":"Gold"}`))
		}
	}

	text, failed := tool_sandbox_open(&s, arguments_of(t, `{"biome":"Coalmine","width":32,"height":32}`))
	testing.expect(t, !failed, "the sandbox must open on a Coalmine region")
	testing.expect(t, strings.contains(text, "Gold"), "the census must be all gold")

	gold, _ := find_material_index(s.world.materials, "Gold")
	counts := make([]int, len(s.world.materials.materials))
	defer delete(counts)
	sandbox_census(&s.sandbox, counts)
	testing.expect(t, counts[gold] == 32*32, "every cell must come from the painted set")
}

@(test)
test_sandbox_open_keeps_what_it_is_not_told :: proc(t: ^testing.T) {
	s := tool_sim(t)
	defer sim_unload(&s)

	tool_sandbox_open(&s, arguments_of(t, `{"x":100,"y":200,"width":40,"height":24}`))
	tool_tick(&s, arguments_of(t, `{"count":5}`))
	testing.expect(t, s.sandbox.tick == 5)

	_, failed := tool_sandbox_open(&s, arguments_of(t, `{}`))
	testing.expect(t, !failed)
	testing.expect(t, s.sandbox.origin_x == 100 && s.sandbox.origin_y == 200, "the place must survive")
	testing.expect(t, s.sandbox.width == 40 && s.sandbox.height == 24, "the size must survive")
	testing.expect(t, s.sandbox.tick == 0, "the run starts again")
}

@(test)
test_enqueue_reports_the_execution_tick :: proc(t: ^testing.T) {
	s := tool_sim(t)
	defer sim_unload(&s)

	text, failed := tool_enqueue_input(&s, arguments_of(t, `{"kind":"spawn","x":16,"y":0,"radius":2,"material":"Sand"}`))
	testing.expect(t, !failed, "a good command must be accepted")
	testing.expect(t, strings.contains(text, "runs on tick 2"), "the reply must name the execution tick")
	testing.expect(t, strings.contains(text, "Sand"), "the reply must name the material")
	testing.expect(t, input_queue_depth(&s.queue) == 1, "the command must wait in the queue")
}

@(test)
test_enqueue_rejects_bad_arguments :: proc(t: ^testing.T) {
	s := tool_sim(t)
	defer sim_unload(&s)

	text, failed := tool_enqueue_input(&s, arguments_of(t, `{"kind":"spawn","x":1,"y":1,"material":"Unobtainium"}`))
	testing.expect(t, failed, "an unknown material must fail")
	testing.expect(t, strings.contains(text, "list_materials"), "the reply must say how to recover")

	_, kind_failed := tool_enqueue_input(&s, arguments_of(t, `{"kind":"boom","x":1,"y":1}`))
	testing.expect(t, kind_failed, "an unknown kind must fail")

	far, far_failed := tool_enqueue_input(&s, arguments_of(t, `{"kind":"noop","x":0,"y":0,"tick":100000}`))
	testing.expect(t, far_failed, "a far tick must fail")
	testing.expect(t, strings.contains(far, "too far ahead"), "the reply must explain the limit")

	_, spawn_failed := tool_enqueue_input(&s, arguments_of(t, `{"kind":"spawn","x":1,"y":1}`))
	testing.expect(t, spawn_failed, "spawn without a material must fail")

	_, erase_failed := tool_enqueue_input(&s, arguments_of(t, `{"kind":"erase","x":1,"y":1,"radius":2}`))
	testing.expect(t, !erase_failed, "erase needs no material")
}

@(test)
test_tick_runs_the_queued_command :: proc(t: ^testing.T) {
	s := tool_sim(t)
	defer sim_unload(&s)

	tool_sandbox_open(&s, arguments_of(t, `{"x":0,"y":-4000,"width":32,"height":24}`))
	tool_enqueue_input(&s, arguments_of(t, `{"kind":"spawn","x":16,"y":0,"radius":1,"material":"Sand"}`))

	early := tool_tick(&s, arguments_of(t, `{"count":1}`))
	testing.expect(t, strings.contains(early, "applied 0 commands"), "the command must wait for its tick")

	late := tool_tick(&s, arguments_of(t, `{"count":2}`))
	testing.expect(t, strings.contains(late, "applied 1 commands"), "the command must run on its tick")
	testing.expect(t, strings.contains(late, "Sand"), "the census must show the sand")
}

@(test)
test_observe_reads_the_sandbox_and_the_world :: proc(t: ^testing.T) {
	s := tool_sim(t)
	defer sim_unload(&s)

	text, failed := tool_observe(&s, arguments_of(t, `{}`))
	testing.expect(t, !failed)
	testing.expect(t, strings.contains(text, "sandbox at tick 0"), "the default source is the sandbox")
	testing.expect(t, strings.contains(text, "legend:"))

	world, world_failed := tool_observe(&s, arguments_of(t, `{"source":"world","width":40,"height":20,"step":256}`))
	testing.expect(t, !world_failed)
	testing.expect(t, strings.contains(world, "world as the generator makes it"))
	testing.expect(t, strings.contains(world, "one character per 256 world cells"))
}

@(test)
test_observe_refuses_a_flood :: proc(t: ^testing.T) {
	s := tool_sim(t)
	defer sim_unload(&s)
	tool_sandbox_open(&s, arguments_of(t, `{"width":1000,"height":1000}`))

	text, failed := tool_observe(&s, arguments_of(t, `{}`))
	testing.expect(t, failed, "a huge map must be refused")
	testing.expect(t, strings.contains(text, "sample"), "the reply must say how to recover")

	sampled, sampled_failed := tool_observe(&s, arguments_of(t, `{"sample":16}`))
	testing.expect(t, !sampled_failed, "sampling must bring the map inside the limit")
	testing.expect(t, strings.contains(sampled, "one character per 16x16 cells"))
}

@(test)
test_queue_peek_lists_the_waiting_commands :: proc(t: ^testing.T) {
	s := tool_sim(t)
	defer sim_unload(&s)

	empty := tool_queue_peek(&s, arguments_of(t, `{}`))
	testing.expect(t, strings.contains(empty, "no commands wait"))

	tool_enqueue_input(&s, arguments_of(t, `{"kind":"spawn","x":5,"y":6,"radius":1,"material":"Water"}`))
	listed := tool_queue_peek(&s, arguments_of(t, `{}`))
	testing.expect(t, strings.contains(listed, "tick 2:"), "the peek must group by tick")
	testing.expect(t, strings.contains(listed, "Water at (5,6)"), "the peek must describe the command")
}

@(test)
test_status_reports_every_part :: proc(t: ^testing.T) {
	s := tool_sim(t)
	defer sim_unload(&s)

	text := tool_world_status(&s)
	testing.expect(t, strings.contains(text, "the ordinary world, world seed"), "the status must name the world it opened")
	testing.expect(t, strings.contains(text, "biome map"))
	testing.expect(t, strings.contains(text, "no tile set is open"))
	testing.expect(t, strings.contains(text, "sandbox 128x72"))
	testing.expect(t, strings.contains(text, "input delay 2 ticks"))
	testing.expect(t, strings.contains(text, "checksum 0x"))
	testing.expect(t, strings.contains(text, "queue: 0 waiting"))
}

@(test)
test_lists_name_everything :: proc(t: ^testing.T) {
	s := tool_sim(t)
	defer sim_unload(&s)

	materials := tool_list_materials(&s)
	for name in s.world.materials.names {
		testing.expectf(t, strings.contains(materials, name), "%s must be listed", name)
	}

	biomes := tool_list_biomes(&s)
	for name in s.world.biomes.names {
		testing.expectf(t, strings.contains(biomes, name), "%s must be listed", name)
	}
}

@(test)
test_a_slow_client_and_a_fast_client_agree :: proc(t: ^testing.T) {
	planned := tool_sim(t)
	defer sim_unload(&planned)
	sim_open_sandbox(&planned, 32, 24, 0, 0, 5, 0)

	stepped := tool_sim(t)
	defer sim_unload(&stepped)
	sim_open_sandbox(&stepped, 32, 24, 0, 0, 5, 0)

	sand, _ := find_material_index(planned.world.materials, "Sand")

	for step in 0 ..< 8 {
		command := Input_Command{kind = .Spawn, x = i32(4 + step*2), y = 0, radius = 1, material = u16(sand)}
		sim_enqueue(&planned, command, i64(step*3))
	}
	sim_run(&planned, 40)

	for step in 0 ..< 8 {
		command := Input_Command{kind = .Spawn, x = i32(4 + step*2), y = 0, radius = 1, material = u16(sand)}
		sim_enqueue(&stepped, command, i64(step*3))
		sim_run(&stepped, 3)
	}
	sim_run(&stepped, 40 - 24)

	testing.expect(
		t,
		sandbox_checksum(&planned.sandbox) == sandbox_checksum(&stepped.sandbox),
		"the send pattern must not change the sandbox",
	)
}

@(test)
test_enqueue_input_accepts_the_new_kinds :: proc(t: ^testing.T) {
	s := tool_sim(t)
	defer sim_unload(&s)

	rock, rock_found := find_material_index(s.world.materials, "Rock")
	if !testing.expect(t, rock_found, "Rock must exist") do return
	sandbox_paint(&s.sandbox, s.world.materials, 32, 30, 20, Cell(rock))

	counts := make([]int, len(s.world.materials.materials))
	defer delete(counts)
	sandbox_census(&s.sandbox, counts)
	before_rock := counts[rock]

	explode_text, explode_failed := tool_enqueue_input(
		&s, arguments_of(t, `{"kind":"explode","x":32,"y":30,"radius":6,"power":80}`),
	)
	testing.expect(t, !explode_failed, explode_text)

	dig_text, dig_failed := tool_enqueue_input(
		&s, arguments_of(t, `{"kind":"dig","x":32,"y":30,"radius":4,"power":8}`),
	)
	testing.expect(t, !dig_failed, dig_text)

	move_text, move_failed := tool_enqueue_input(
		&s, arguments_of(t, `{"kind":"move","buttons":["right","run"],"pressed":["right"]}`),
	)
	testing.expect(t, !move_failed, move_text)

	sim_run(&s, 5)

	sandbox_census(&s.sandbox, counts)
	testing.expectf(
		t, counts[rock] < before_rock,
		"explode and dig together must have removed some rock, got %d of %d before", counts[rock], before_rock,
	)
}

@(test)
test_enqueue_input_accepts_a_throw_button :: proc(t: ^testing.T) {
	s := tool_sim(t)
	defer sim_unload(&s)

	move_text, move_failed := tool_enqueue_input(
		&s, arguments_of(t, `{"kind":"move","buttons":["throw"]}`),
	)
	testing.expect(t, !move_failed, move_text)
}

@(test)
test_enqueue_input_rejects_a_bad_button_and_a_missing_power :: proc(t: ^testing.T) {
	s := tool_sim(t)
	defer sim_unload(&s)

	_, bad_button := tool_enqueue_input(&s, arguments_of(t, `{"kind":"move","buttons":["fly"]}`))
	testing.expect(t, bad_button, "an unknown button name must fail")

	_, no_power := tool_enqueue_input(&s, arguments_of(t, `{"kind":"explode","x":1,"y":1,"radius":2}`))
	testing.expect(t, no_power, "explode without a power must fail")
}

@(test)
test_player_move_moves_the_wizard_and_player_status_reports_it :: proc(t: ^testing.T) {
	s := tool_sim(t)
	defer sim_unload(&s)

	before := tool_player_status(&s)
	testing.expect(t, strings.contains(before, "wizard at"), "status must report a position")
	testing.expect(t, !strings.contains(before, "is following him"), "sim_load must not yet be following him")

	start_x := s.player.x

	text, failed := tool_player_move(&s, arguments_of(t, `{"buttons":["right","run"],"ticks":60}`))
	testing.expect(t, !failed, text)
	testing.expect(t, s.follow_player, "player_move must turn on following")
	testing.expectf(t, s.player.x > start_x, "holding right must move him right, got %f from %f", s.player.x, start_x)

	after := tool_player_status(&s)
	testing.expect(t, strings.contains(after, "is following him"), "status must say the sandbox is following him now")
}

@(test)
test_player_move_points_the_digger_in_degrees :: proc(t: ^testing.T) {
	s := tool_sim(t)
	defer sim_unload(&s)

	text, failed := tool_player_move(&s, arguments_of(t, `{"buttons":["dig"],"ticks":1,"aim":90}`))
	testing.expect(t, !failed, text)
	testing.expectf(t, s.player.aim == PLAYER_AIM_DOWN, "90 degrees must read as straight down, got %d", s.player.aim)

	_, up_failed := tool_player_move(&s, arguments_of(t, `{"buttons":["dig"],"ticks":1,"aim":270}`))
	testing.expect(t, !up_failed, "an aim of 270 must be accepted")
	testing.expectf(t, s.player.aim == PLAYER_AIM_UP, "270 degrees must read as straight up, got %d", s.player.aim)

	s.player.facing = -1
	_, none_failed := tool_player_move(&s, arguments_of(t, `{"buttons":[],"ticks":1}`))
	testing.expect(t, !none_failed, "a move with no aim must be accepted")
	testing.expectf(t, s.player.aim == PLAYER_AIM_LEFT, "with no aim he must point the way he faces, got %d", s.player.aim)
}
