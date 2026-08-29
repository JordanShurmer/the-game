# The web build

The game runs in a browser, and the browser is how it reaches a phone.
The same Odin sources build twice: once for the desktop window, and
once for WebAssembly. Emscripten links the WebAssembly against a
raylib built for the web, and the page draws through WebGL 2.

```sh
sudo tools/install-web-toolchain.sh   # emscripten and a raylib for the web
make web                              # web/build/index.html
tools/serve_web.py                    # http://127.0.0.1:8000
```

There is no second game. Every rule below exists to keep one source
tree that both targets build, because two trees drift apart in a week.

## Why the browser, and not an APK

Odin has no Android target. The compiler builds for Linux, Darwin,
Windows, the BSDs and WebAssembly, and `vendor:raylib` ships no
library for `arm64-v8a`. A `-subtarget:android` flag exists, but no
vendored raylib answers it, so a native Android build is not a
half-day of work.

The browser is. Android runs the same page every desktop browser runs,
and a WebView or a Trusted Web Activity wraps that page in an APK with
no game code of its own. `docs/web.md`, "The APK", holds that recipe.

## What the web cannot have

Four things the desktop build has do not exist in a browser, and each
one is a rule about where code may live.

- **No `core:os`.** The package `game` imports it nowhere. Every file
  the game reads goes through `src/file.odin`, which is raylib's own
  file reader on every target. In the browser the files are inside the
  page, preloaded by Emscripten under the same `data/...` paths.
- **No `core:testing`.** That package reaches `core:os`, so a browser
  build cannot hold it. The tests stay beside the code they cover and
  import `src/check` instead, which is `core:testing` on the desktop
  and four stubs in the browser.
- **No AVX2.** The wide weight pass is amd64 assembly. It is tagged
  `#+build amd64`, and `src/sandbox_step_wide.odin` answers for every
  other machine with the plain path. The browser therefore runs the
  portable SIMD step, not the assembly one.
- **No blocking loop.** A page may not sit in `for
  !rl.WindowShouldClose()`. The body of that loop is `app_frame`, a
  procedure. The desktop calls it in a loop and the browser hands it
  to the page.

## The shaders

Desktop OpenGL takes GLSL 330. WebGL 2 takes GLSL ES 300. The two
dialects are the same language for everything the game writes; only
the first two lines differ. So no shader file names a version. The
loader puts the header on, `material_shader_header`, and the target
picks which one:

```glsl
#version 330                    // the desktop
#version 300 es                 // the browser
precision highp float;
```

A material shader is still one file, `data/shaders/materials/<name>.fs`,
and it still works on both. This is why the web build needs a raylib
built with `GRAPHICS_API_OPENGL_ES3`: the raylib that Odin vendors for
the web is WebGL 1, which rejects GLSL ES 300 and every array
constructor the prelude uses.

## The touch controls

A phone has no keys. `src/touch.odin` reads the touch points raylib
reports and returns the same `Held` set the keys return, so nothing
downstream knows which one moved the wizard. The map from a point to a
control is a pure procedure of the point and the size of the screen,
which is what the tests measure.

## The window

`WINDOW_W` and `WINDOW_H` are `#config` constants. The desktop keeps
1280x720. The web build sets its own, because the sandbox is the size
of the window: every cell of it steps every tick, and a phone is not a
desktop.

## The APK

The page is the whole game, so the APK holds no game code. Wrap it
either way:

- **A Trusted Web Activity.** `bubblewrap init` against the deployed
  URL. The APK is a manifest and an icon. The page must be on HTTPS.
- **A WebView.** One activity, `loadUrl("file:///android_asset/...")`,
  and `web/build/` copied into `assets/`. It works offline and needs
  no server.

Both need the Android SDK, and neither needs Kotlin beyond the twenty
lines the template writes.
