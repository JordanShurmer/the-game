# Build and test the game.
#
# The Odin compiler must be on the PATH. Run every target from the
# repository root, because the data paths are relative.
#
# Built and tested against the Odin nightly of 2026-08-20. The game
# uses `asm` templates, which no monthly release holds yet; see
# docs/toolchain.md, "Why a nightly".

ODIN ?= odin
BIN  ?= bin

SOURCES := $(wildcard src/*.odin)

.PHONY: all game mcp shot bench test check run web clean

all: game mcp shot

# The game window.
game: $(BIN)/the-game

$(BIN)/the-game: $(SOURCES)
	@mkdir -p $(BIN)
	$(ODIN) build src -out:$@ -o:speed

# The MCP server. An MCP client starts this binary. It loads the same
# world and edits it through the same procedures, with no window.
mcp: $(BIN)/game-mcp

$(BIN)/game-mcp: $(SOURCES) $(wildcard cmd/mcp/*.odin)
	@mkdir -p $(BIN)
	$(ODIN) build cmd/mcp -out:$@ -o:speed

# The world as a PNG, with no window. Run it from the repository root:
#   ./bin/shot biome=Coalmine grid=1 out=shots/coalmine.png
shot: $(BIN)/shot

$(BIN)/shot: $(SOURCES) $(wildcard cmd/shot/*.odin)
	@mkdir -p $(BIN)
	$(ODIN) build cmd/shot -out:$@ -o:speed

# What a tick costs, on a real region of the shipped world. Run it from
# the repository root:
#   ./bin/bench biome=Lake
bench: $(BIN)/bench

$(BIN)/bench: $(SOURCES) $(wildcard cmd/bench/*.odin)
	@mkdir -p $(BIN)
	$(ODIN) build cmd/bench -out:$@ -o:speed

# The game as a page, which is how it reaches a phone. It needs the web
# toolchain: sudo tools/install-web-toolchain.sh. See docs/web.md.
#
# RAYLIB_WASM_LIB=env.o is what makes the foreign names raylib's own
# rather than the path of a library, which is what the emscripten
# linker looks for.
EMSDK      ?= $(HOME)/emsdk
EMCC       ?= $(EMSDK)/upstream/emscripten/emcc
RAYLIB_WEB ?= /usr/local/lib/raylib-web
WEB        ?= web/build

web: $(WEB)/index.html

$(WEB)/index.html: $(SOURCES) $(wildcard cmd/web/*.odin) $(wildcard src/check/*.odin) \
		web/entry.c web/shell.html $(shell find data -type f)
	@mkdir -p $(WEB)
	$(ODIN) build cmd/web -target:freestanding_wasm32 -build-mode:obj -o:speed \
		-define:RAYLIB_WASM_LIB=env.o -out:$(WEB)/game.wasm.o
	$(EMCC) -o $@ \
		web/entry.c $(WEB)/game.wasm.o $(RAYLIB_WEB)/libraylib.web.a \
		-O2 -sUSE_GLFW=3 -sALLOW_MEMORY_GROWTH -sINITIAL_MEMORY=192MB \
		-sSTACK_SIZE=4mb -sMIN_WEBGL_VERSION=2 -sMAX_WEBGL_VERSION=2 \
		-sEXPORTED_RUNTIME_METHODS=HEAPF32 --preload-file data \
		--shell-file web/shell.html

# The whole suite lives beside the code it covers.
test:
	$(ODIN) test src

check:
	$(ODIN) check src -vet

run: game
	./$(BIN)/the-game

clean:
	rm -rf $(BIN)
