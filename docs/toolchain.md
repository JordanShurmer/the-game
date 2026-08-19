# The toolchain

The game is built with the Odin compiler and links the raylib library
that Odin vendors. Nothing else. A machine that already has `odin` on
the PATH needs none of this page.

```sh
sudo tools/install-toolchain.sh   # about half a minute
odin version                      # odin version dev-2026-08-nightly:902106f
```

## What it does, and why

**Odin.** The repository is built against the `dev-2026-08` release.
Odin publishes a release archive for each one, and that archive holds
the compiler, the core libraries, and the vendored binaries. The
script downloads it and unpacks it. Nothing is built, and nothing is
cloned.

The compiler in the archive is a static executable. It carries the
LLVM it needs, so the machine needs no `llvm-dev` package to run it.

**raylib.** The bindings in `vendor:raylib` link
`vendor/raylib/linux/libraylib.a` inside the Odin tree. The release
archive ships that file as the real library, so there is nothing to do
about it.

Do not clone the Odin repository to get that file. The repository
keeps the vendored binaries in Git LFS, and a clone gives you the
library only if LFS objects can be fetched:

- Where they cannot, and `git-lfs` is not installed, the clone
  succeeds and writes a 132 byte pointer where the library should be.
  The link then fails with missing symbols, well away from the cause.
- Where they cannot, and `git-lfs` is installed, the smudge filter
  fails the checkout, and the clone leaves a half tree behind.

**Packages.** Three, and only for the link:

| Package | Why |
| --- | --- |
| `clang` | the linker Odin calls |
| `libx11-dev` | the static raylib names `X11`; it loads OpenGL at run time, so no GL package is needed |
| `make` | the `Makefile` targets |

## Another release

```sh
ODIN_RELEASE=dev-2026-09 sudo tools/install-toolchain.sh
```

Each release unpacks into its own directory in `$HOME`, about 220 MB,
and `/usr/local/bin/odin` is a symlink into the one in use. So a
second run of an installed release only moves the symlink, and going
back to a release you have had is as quick. Delete the directories you
do not want.

The archive reports itself as `dev-2026-08-nightly:902106f`, where a
compiler built from the `dev-2026-08` tag reports
`dev-2026-08:8412dc3`. The release is cut from the nightly build of
that tag. The two behave the same for this repository.

## From source instead

Only for a platform with no release archive, or a commit between
releases. It takes about five minutes and needs `llvm-18-dev` on top
of the packages above, because a compiler built here links LLVM
rather than carrying it.

```sh
GIT_LFS_SKIP_SMUDGE=1 git clone --depth 1 --branch dev-2026-08 \
	https://github.com/odin-lang/Odin ~/odin
cd ~/odin && ./build_odin.sh release
```

`GIT_LFS_SKIP_SMUDGE` holds the LFS files as pointers, so the checkout
cannot fail on a binary this repository never links.

That leaves raylib to put in place. The pointer names the SHA-256 of
the library it stands for, and the LFS media host serves that library
to anyone:

```sh
cd ~/odin
git show HEAD:vendor/raylib/linux/libraylib.a          # the pointer, and the oid
curl -fL -o vendor/raylib/linux/libraylib.a \
	https://media.githubusercontent.com/media/odin-lang/Odin/dev-2026-08/vendor/raylib/linux/libraylib.a
sha256sum vendor/raylib/linux/libraylib.a              # must equal the oid
```

Where even that host is out of reach, build raylib at the version the
bindings name in `vendor/raylib/raylib.odin`, `VERSION`. raylib 6.0
built with `PLATFORM=PLATFORM_DESKTOP_GLFW RAYLIB_LIBTYPE=STATIC` on
Linux gives an archive whose SHA-256 is that same oid, so it is the
shipped library and not a lookalike. That build needs the X
development packages: `libxrandr-dev libxinerama-dev libxcursor-dev
libxi-dev libgl1-mesa-dev`.

## No display needed

Nothing in the test suite opens a window. The tests read and write
PNG files through raylib, and `bin/shot` draws the world into a PNG,
both of which work with no X server and no graphics driver. Only
`bin/the-game` needs a display.
