# Build and test the game.
#
# The Odin compiler must be on the PATH. Run every target from the
# repository root, because the data paths are relative.
#
# Built and tested against the dev-2026-08 release.

ODIN ?= odin
BIN  ?= bin

SOURCES := $(wildcard src/*.odin)

.PHONY: all game mcp shot test check run clean

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

# The whole suite lives beside the code it covers.
test:
	$(ODIN) test src

check:
	$(ODIN) check src -vet

run: game
	./$(BIN)/the-game

clean:
	rm -rf $(BIN)
