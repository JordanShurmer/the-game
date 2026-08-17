# Build and test the game.
#
# The Odin compiler must be on the PATH. Run every target from the
# repository root, because the data paths are relative.
#
# The current core:os API changed after the dev-2026-02 release, so
# build with dev-2026-02 or an older one until the port is done.

ODIN ?= odin
BIN  ?= bin

SOURCES := $(wildcard src/*.odin)

.PHONY: all game mcp test check run clean

all: game mcp

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

# The whole suite lives beside the code it covers.
test:
	$(ODIN) test src

check:
	$(ODIN) check src -vet

run: game
	./$(BIN)/the-game

clean:
	rm -rf $(BIN)
