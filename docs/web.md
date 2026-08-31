# The web build

The game runs in a browser, and the browser is how it reaches a phone.
The same sources build twice: once for the desktop window, and once for
WebAssembly. Emscripten links the WebAssembly against a raylib built
for the web, and the page draws through WebGL 2.

```sh
sudo tools/install-web-toolchain.sh   # emscripten, and a raylib for the web
make web                              # web/build/index.html
tools/serve_web.py                    # http://127.0.0.1:8000
tools/serve_web.py --any-host         # and from a phone on the network
```

There is no second game. Every rule below exists to keep one source
tree that both targets build, because two trees drift apart in a week.

## Why the browser, and not a native APK

Odin builds for Linux, Darwin, Windows, the BSDs and WebAssembly, and
`vendor:raylib` ships no library for `arm64-v8a`. A `-subtarget:android`
flag exists on the compiler, and no vendored raylib answers it, so a
native Android build is not a half-day of work.

The browser is. Android runs the same page every desktop browser runs,
and a WebView wraps that page in an APK with no game code of its own.
"The APK" below is the recipe, and `tools/build-apk.sh` is the whole of
it.

## What the web cannot have

Four things the desktop build has do not exist in a browser, and each
one is a rule about where code may live.

- **No `core:os`.** Importing it on a wasm target is a compile time
  panic, and on a freestanding one its path constants do not resolve.
  The package `game` imports it nowhere. Every file the game reads goes
  through `src/file.odin`, which is raylib's own reader on every target,
  and every diagnostic goes through the debug ladder in
  `src/noise.odin`, whose three target-dependent calls -- where the rung
  comes from, where the talk goes, where a result goes -- are answered
  by `src/noise_desktop.odin` and, through raylib's log, by
  `src/noise_web.odin`.

  In the browser the data files sit inside the page, laid out by
  emscripten under the same names, so `data/materials.txt` is one path
  everywhere and no loader knows which target it is on.

  Two files stay behind, and both are only what a browser does not
  have: `main_desktop.odin`, the arguments and the loop that runs until
  the window closes, and `mcp_serve.odin`, the stdin and stdout of the
  MCP server. Everything the server drives is in the package.

- **No `core:testing`.** It reaches `core:os`, and one import anywhere
  in a package stops the whole build -- so a browser build of the game
  is a browser build of the tests that live in the same files.
  `src/check` is four names wide: T, expect, expectf, expect_value.
  On the desktop each is `core:testing`'s own, aliased, so `^check.T`
  **is** `^testing.T` and `odin test src` runs what it always ran. In
  the browser they are the same four names doing nothing.

- **No AVX2.** The wide weight pass is amd64 assembly, and an `asm`
  template cannot be hidden behind a `when`: the file is tagged
  `#+build amd64` and `sandbox_step_wide_off.odin` answers for every
  other machine with the plain path. Nothing else about the simulation
  changes; the portable SIMD step in `sandbox_step_simd.odin` is what
  the browser runs.

- **No blocking loop.** A page that never returns to the browser never
  draws and never reads a touch. The body of the old `for
  !rl.WindowShouldClose()` is `app_frame`, a procedure. The desktop
  calls it in a loop; `cmd/web` hands it to emscripten.

There is a fifth, smaller one: **no clock in `core:time`** -- `tick_now`
answers zero -- so `src/prof.odin` takes emscripten's monotonic clock
in a browser. A profile of nothing but zeroes is worse than no profile.

## What the page is made of

| Path | What it is |
| --- | --- |
| `cmd/web/main.odin` | the browser entry: boot, and one frame handed to the page |
| `cmd/web/heap.odin` | the heap, over emscripten's malloc |
| `web/entry.c` | four lines, and the only C in the game |
| `web/shell.html` | the page: the canvas, the front, the fit |
| `web/manifest.webmanifest` | what makes it installable |
| `android/` | the APK: a manifest, one WebView, and the page in its assets |

An Odin object file has no `_start`, so `cmd/web` exports `game_boot`
and `web/entry.c` calls it. `game_boot` starts the Odin runtime by
hand: until it runs, no `@(init)` procedure has run and the light
tables the world is drawn with are empty.

A freestanding WebAssembly target has no allocator at all -- the
default answers Out_Of_Memory to the first byte, and the default
temporary allocator is a nil allocator -- so both come from
emscripten's malloc, which is also what raylib allocates through. The
game and the library it draws with share one heap.

## The shaders

Desktop OpenGL takes GLSL 330. WebGL 2 takes GLSL ES 300. For
everything the game writes -- `in`, `out`, `texture`, an array
constructor, a loop over a count it is handed -- the two are the same
language, so **no shader file names a version**. `src/shader_header.odin`
holds both headers and the loader puts one on:

```glsl
#version 330                    // the desktop
#version 300 es                 // the browser, and a precision with it
```

ES leaves a fragment shader with no precision of its own, so the
browser's header names one. It is `highp`: the g-buffer is read a texel
at a time, and `mediump` loses the cell before the picture does.

Two things about ES are worth knowing before writing a shader:

- **It keeps words 330 does not.** `patch` was a local in two material
  files; they compiled on the desktop and came out flat in the page,
  which shows up as a look and not as an error.
  `test_no_shader_uses_a_word_the_browser_keeps_for_itself` walks every
  shader for the words ES reserves.
- **The vendored raylib for the web is WebGL 1**, which rejects GLSL ES
  300 and every array constructor the prelude is written with. Holding
  two dialects of twenty-two material shaders is a worse price than
  building the library once, so `tools/install-web-toolchain.sh` builds
  raylib 6.0 with `GRAPHICS_API_OPENGL_ES3`.

## The touch controls

A phone gives the game a list of points and nothing else.
`src/touch.odin` turns that list into the same `Player_Input` the keys
make: a pad on the left walks and runs, three buttons on the right
jump, dig and throw, and the pad aims, because a wizard who digs and
throws needs a direction and there is no cursor to take one from.

Every control is placed from the corner it belongs to and measured in
shares of the shorter side of the screen, because a thumb is the same
size on a wide screen and a tall one. Two tests hold the layout: no two
controls may overlap, and none may fall off the edge.

The controls appear the first time the glass is touched, and never on a
desktop. That flag does one more thing: a browser makes a mouse out of
a thumb, so a hand that has touched the screen once would dig at every
step and aim at wherever it last let go. A touched screen has no
cursor, and the game stops reading one.

## Looking at the page

`bin/shot` is how to look at the world. `tools/play_web.mjs` is how to
look at the page:

```sh
make web
node tools/play_web.mjs shots/web 844 390    # a phone's size
```

It loads the page in a headless browser, presses play, holds a thumb on
the pad and on JUMP the way a hand would, and writes a picture at each
step. Everything the page says goes to the terminal, which is where a
shader that will not compile in the browser turns up. It needs node and
playwright, which are not part of the game's toolchain; the header of
the file says how to get them, and `node_modules` is ignored by git.

The browser it drives has no GPU and draws in software, so it is a few
frames a second there and that says nothing about a phone.

## The window, and what a frame costs

`WINDOW_W` and `WINDOW_H` are `#config` constants, and the sandbox is
the size of the window: every cell of it steps every tick and is shaded
every frame, so those two numbers are most of what a frame costs.

```sh
odin build cmd/web -define:WINDOW_W=960 -define:WINDOW_H=540 ...
```

Measured in a browser on the shipped world, at 1280x720: about 1.7 ms
of simulation a frame over its ticks, and 3.5 ms of the frame itself --
shade 1.7, draw 1.0, the material marks 0.7. The simulation is not what
a phone will struggle with. The fragments are: 921,600 of them, through
twenty-two material shaders. That is the knob to turn first, and F3
still prints the phases, in the page as in the window.

## The APK

The page is the whole game, so the APK holds no game code:
`android/AndroidManifest.xml`, one WebView in
`android/src/com/example/thegame/MainActivity.java`, and `web/build` in
its assets.

```sh
make web
ANDROID_HOME=~/android-sdk tools/build-apk.sh
adb install -r android/build/the-game.apk
```

It needs a JDK and two Android packages, `platforms;android-34` and
`build-tools;34.0.0`. It calls those tools directly rather than through
Gradle, because there is nothing here for a build system to work out:
compile one class, dex it, pack the page beside it, sign it. The APK
comes to about 800 kB.

Two things in that WebView are not decoration:

- **The page is served on an origin, not off a file:// path.** A
  file:// page gets no fetch, no module streaming, and no shared origin
  between the page and the `.wasm` beside it. The activity answers
  every request under `https://the.game/` out of the assets, and
  nothing goes to a network. The APK asks for no INTERNET permission.
- **A `.wasm` must be named `application/wasm`.** A WebView will not
  run a module it was handed as text.

The APK is signed with a debug key, which the script makes if it is not
there: good enough to sideload, not good enough to publish. A release
needs a key of your own, and the package name in the manifest is
`com.example.thegame` on purpose.

**What has not been proven.** The page is played in a browser, by hand
and by a headless one. The APK is built, signed, and its contents
checked -- it has never been run on a phone, because nothing here has
one. The Java in it is forty lines, and those two rules above are what
it is for.

A Trusted Web Activity is the other way to wrap it, if the page is
already deployed over HTTPS: `bubblewrap init` against the URL, and the
APK is a manifest and an icon. `web/manifest.webmanifest` is what it
reads.

## The release

Every push to `main` builds the APK and publishes it, in
`.github/workflows/release.yml`. It is the three commands above in
order -- the two toolchain installs, then `make web` and
`tools/build-apk.sh` -- with the suite in front of them, so a push that
fails a test publishes nothing.

The release is tagged `v0.1.<run>` and carries two files: the APK, and
the page as a zip for anyone who would rather serve it than install it.
`<run>` is the workflow's own run number, which is also the APK's
`versionCode`, because Android will not install a version it already
has and the number must only ever climb.

The web toolchain is half an hour of downloading and building, so it is
cached under `.toolchain` against the hash of
`tools/install-web-toolchain.sh`: a change to what that script installs
is a change to what is cached, and nothing else rebuilds it.

### The key, and why an APK will not install

Android takes an update only from the key that installed the app. Where
the key differs it refuses, and it says no more than "App not
installed": not which key, not that a key is the reason. So a key made
per build is a build nobody can update to, and a runner is a fresh
checkout, which is where a build would make one.

The key is therefore in the repository: `android/debug.keystore`, alias
`thegame`, password `android`. Every build that is not handed another
key signs with that one -- yours, a contributor's, the runner's -- so
every release installs over the release before it, and a local build
installs over a release.

**It is a published private key, and it is only good for sideloading.**
Anyone who has the repository can sign an APK with it, so it can never
be the key a real app is released under. That is the trade it was picked
for: no setup, and every build installs.

Two things follow from it. A release built before this key was committed
was signed by a key of its own, so the first install after it still
needs the old app off the phone:

```sh
adb uninstall com.example.thegame     # or hold the icon and uninstall
adb install the-game-0.1.N.apk
```

And the release note carries the certificate's SHA-256 and says which
key signed the APK, so when an install is refused the answer is on the
release page rather than nowhere.

Four secrets give the build a key of its own, and it uses them the
moment they are there:

| Secret | What it is |
| --- | --- |
| `ANDROID_KEYSTORE_BASE64` | the keystore, `base64 -w0` |
| `ANDROID_KEYSTORE_PASS` | its password |
| `ANDROID_KEY_ALIAS` | the key inside it |
| `ANDROID_KEY_PASS` | that key's password, if it differs |

That is the key a published app needs: one that has never been in a
repository. Make it, and read it into the secrets, once:

```sh
keytool -genkeypair -keystore the-game.jks -alias thegame \
    -keyalg RSA -keysize 2048 -validity 10000 \
    -dname "CN=The Game, OU=None, O=None, L=None, S=None, C=ZZ"
base64 -w0 the-game.jks        # -> ANDROID_KEYSTORE_BASE64
```

Keep that file. It is the app's identity from then on: a phone will take
an update only from the key that installed it, and a key that is lost
cannot be replaced, only started again under another package name.

A published APK also needs a package name that is yours: the manifest
says `com.example.thegame` on purpose, and the first release under a
real name is the one that fixes it, because a package name cannot
change afterwards.
