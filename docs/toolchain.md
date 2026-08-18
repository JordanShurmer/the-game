# The toolchain

The game is built with the Odin compiler and links the raylib library
that Odin vendors. Nothing else. A machine that already has `odin` on
the PATH needs none of this page.

```sh
sudo tools/build-toolchain.sh     # about five minutes
odin version                      # odin version dev-2026-08:8412dc3
```

## What it does, and why

**Odin.** The repository is built against the `dev-2026-08` release,
which is the last full release tag. The compiler is one translation
unit and builds in about ninety seconds, but it links LLVM, so the
`llvm-18-dev` package has to be there first. The runtime alone is not
enough: the build reads the headers and the component libraries.

**raylib.** The bindings in `vendor:raylib` link
`vendor/raylib/linux/libraylib.a` inside the Odin tree. The Odin
repository keeps that archive in Git LFS. A clone made where LFS
objects cannot be fetched still succeeds, but the file it writes is a
132 byte pointer, and the link then fails with missing symbols. The
script builds raylib from source at the version the bindings name and
copies the archive into place.

The two agree exactly. raylib 6.0 built with
`PLATFORM=PLATFORM_DESKTOP_GLFW RAYLIB_LIBTYPE=STATIC` on Linux gives
an archive whose SHA-256 is the object id in the LFS pointer, so this
is the shipped library and not a lookalike.

`vendor/raylib/raylib.odin` names the version it binds to. Change
`RAYLIB_TAG` with `ODIN_RELEASE` if you move to another Odin release.

## Another release

```sh
ODIN_RELEASE=dev-2026-09 RAYLIB_TAG=6.0 sudo tools/build-toolchain.sh
```

The script keeps its clones in `$HOME`, so a second run rebuilds
without downloading again. Delete `~/odin` and `~/raylib` to start
over.

## No display needed

Nothing in the test suite opens a window. The tests read and write
PNG files through raylib, and `bin/shot` draws the world into a PNG,
both of which work with no X server and no graphics driver. Only
`bin/the-game` needs a display.
