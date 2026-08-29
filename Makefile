# Build and test the game.
#
# The Odin compiler must be on the PATH. Run every target from the
# repository root, because the data paths are relative.
#
# Built and tested against the Odin nightly of 2026-08-20. The game
# uses `asm` templates, which no monthly release holds yet; see
# docs/toolchain.md, "Why a nightly".
#
# A build says one line for each binary it wrote, and nothing else.
# The debug ladder is V, and it is the same ladder everything else in
# the toolset reads:
#
#   make          the binaries it wrote                    (V=0)
#   make V=1      the compiler command behind each one
#   make V=2      the compiler's own output as well
#   make V=3      everything, the graphics trace log included
#
# V reaches the tests and the binaries too, as GAME_DEBUG.

ODIN ?= odin
BIN  ?= bin
V    ?= 0

SOURCES := $(wildcard src/*.odin)

export GAME_DEBUG = $(V)

# The compiler is already quiet when a build goes right: it says
# nothing, and a warning or an error is not the normal path. So the
# rungs here are about what the Makefile itself says. At V=0 the
# command is hidden and only the file it wrote is named. From V=1 the
# command is echoed, and from V=2 the compiler is asked to time itself.
ifeq ($(V),0)
  Q     := @
  TIMES :=
else ifeq ($(V),1)
  Q     :=
  TIMES :=
else
  Q     :=
  TIMES := -show-timings
endif

# What a target says when it is done. One line, one binary.
define wrote
@printf '%s  %s\n' "$$(du -h $(1) | cut -f1)" "$(1)"
endef

.PHONY: all game mcp shot bench test check run web icons clean help

all: game mcp shot

help:
	@sed -n '2,20p' Makefile | cut -c3-
	@printf '\ntargets: all game mcp shot bench test check run web clean\n'

# The game window.
game: $(BIN)/the-game

$(BIN)/the-game: $(SOURCES)
	$(Q)mkdir -p $(BIN)
	$(Q)$(ODIN) build src -out:$@ -o:speed $(TIMES)
	$(call wrote,$@)

# The MCP server. An MCP client starts this binary. It loads the same
# world and edits it through the same procedures, with no window.
mcp: $(BIN)/game-mcp

$(BIN)/game-mcp: $(SOURCES) $(wildcard cmd/mcp/*.odin)
	$(Q)mkdir -p $(BIN)
	$(Q)$(ODIN) build cmd/mcp -out:$@ -o:speed $(TIMES)
	$(call wrote,$@)

# The world as a PNG, with no window. Run it from the repository root:
#   ./bin/shot biome=Coalmine grid=1 out=shots/coalmine.png
shot: $(BIN)/shot

$(BIN)/shot: $(SOURCES) $(wildcard cmd/shot/*.odin)
	$(Q)mkdir -p $(BIN)
	$(Q)$(ODIN) build cmd/shot -out:$@ -o:speed $(TIMES)
	$(call wrote,$@)

# What a tick costs, on a real region of the shipped world. Run it from
# the repository root:
#   ./bin/bench biome=Lake
bench: $(BIN)/bench

$(BIN)/bench: $(SOURCES) $(wildcard cmd/bench/*.odin)
	$(Q)mkdir -p $(BIN)
	$(Q)$(ODIN) build cmd/bench -out:$@ -o:speed $(TIMES)
	$(call wrote,$@)

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
		web/entry.c web/shell.html web/manifest.webmanifest $(shell find data -type f)
	$(Q)mkdir -p $(WEB)
	$(Q)$(ODIN) build cmd/web -target:freestanding_wasm32 -build-mode:obj -o:speed \
		-define:RAYLIB_WASM_LIB=env.o -out:$(WEB)/game.wasm.o
	$(Q)$(EMCC) -o $@ \
		web/entry.c $(WEB)/game.wasm.o $(RAYLIB_WEB)/libraylib.web.a \
		-O2 -sUSE_GLFW=3 -sALLOW_MEMORY_GROWTH -sINITIAL_MEMORY=192MB \
		-sSTACK_SIZE=4mb -sMIN_WEBGL_VERSION=2 -sMAX_WEBGL_VERSION=2 \
		-sEXPORTED_RUNTIME_METHODS=HEAPF32 --preload-file data \
		--shell-file web/shell.html
	$(Q)cp web/manifest.webmanifest web/icon-192.png web/icon-512.png $(WEB)/
	$(call wrote,$@)

# The icons the page and an APK are known by: the wizard where he
# starts, drawn by the game itself. They are data in the repository, so
# this only needs running when he is redrawn.
icons: $(BIN)/shot
	$(Q)./$(BIN)/shot player=1 w=64 h=64 scale=8 out=web/icon-512.png
	$(Q)./$(BIN)/shot player=1 w=64 h=64 scale=3 out=web/icon-192.png

# The whole suite lives beside the code it covers. tools/test.sh is the
# quiet front for `odin test src`: a mark for each test, and the
# failures, with their file and line, at the end.
test:
	$(Q)tools/test.sh $(if $(filter-out 0,$(V)),-d$(V),)

check:
	$(Q)$(ODIN) check src -vet $(TIMES) && printf '%s  src\n' "✓"

run: game
	$(Q)./$(BIN)/the-game

clean:
	$(Q)rm -rf $(BIN)
