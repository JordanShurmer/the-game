/* The one line of C in the game.
 *
 * Emscripten starts a module at `main`. An Odin object file has no
 * entry point of its own -- `-build-mode:obj` builds no `_start` -- so
 * cmd/web exports `game_boot` and this calls it.
 *
 * See docs/web.md. */
extern void game_boot(void);

int main(void) {
	game_boot();
	return 0;
}
