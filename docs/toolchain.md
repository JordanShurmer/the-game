# The toolchain

The game is built with the Odin compiler and links the raylib library
that Odin vendors. Nothing else. A machine that already has `odin` on
the PATH needs none of this page.

```sh
sudo tools/install-toolchain.sh   # about half a minute
odin version                      # odin version dev-2026-08-nightly:ec04cee
```

## Why a nightly

The game is built against a **nightly** archive, and not against a
monthly release. It uses `asm` templates, and those reached the tip of
Odin on 9 August 2026, three days after `dev-2026-08` was cut. No
release holds them yet.

That is a syntax feature, so there is no way to write the code twice
and pick one at build time. A `when` block is still parsed, and a
compiler that cannot parse an `asm` template fails every file that
holds one. The choice is the whole repository, either way.

Read `src/sandbox_step_asm.odin` for what the templates buy and why the
game takes them. The cost is on this page:

- **A nightly lives about eight days.** The index keeps the last eight
  and drops the rest, so the day named in the script goes away on its
  own. The script then takes the newest nightly there is and says so,
  which is why a checkout from a month ago still installs.
- **The compiler moves under the code.** Fifty commits touched `asm`
  in the eleven days after it landed. A nightly that builds the game
  today is not a promise about tomorrow, and the fix for a nightly
  that fails is usually the next one.
- **amd64 only.** `asm` templates are amd64 for now, so an arm64
  machine can no longer build the game. The nightly index publishes an
  arm64 archive and the script still takes it, so this ends when Odin
  extends the templates and not when the script changes.

The plan is to go back to a release: `dev-2026-09` is cut in the first
week of September and should be the first one that holds `asm`
templates. When it is out, set `ODIN_RELEASE` in the script, delete
this section, and the eight day window stops mattering.

## What it does, and why

**Odin.** The script reads the nightly index, picks the day the game
was last tested against, and downloads that archive. The archive holds
the compiler, the core libraries, and the vendored binaries. Nothing
is built, and nothing is cloned.

The compiler in the archive is a static executable. It carries the
LLVM it needs, so the machine needs no `llvm-dev` package to run it.

Last, the script builds one file that holds an `asm` template. A
compiler that cannot parse it cannot build the game, and one clear
line is better than a wall of syntax errors in `src/`.

**raylib.** The bindings in `vendor:raylib` link
`vendor/raylib/linux/libraylib.a` inside the Odin tree. Both the
release and the nightly archives ship that file as the real library,
so there is nothing to do about it.

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
| `python3` | reads the nightly index, which is JSON |
| `libx11-dev` | the static raylib names `X11`; it loads OpenGL at run time, so no GL package is needed |
| `make` | the `Makefile` targets |

## Another build

```sh
ODIN_NIGHTLY=2026-08-19 sudo tools/install-toolchain.sh   # that day
ODIN_NIGHTLY=latest     sudo tools/install-toolchain.sh   # the newest
ODIN_RELEASE=dev-2026-09 sudo tools/install-toolchain.sh  # a release
```

`ODIN_NIGHTLY` names a day of the index, and any day that is no longer
kept falls back to the newest one. `latest` is that fallback asked for
on purpose. `ODIN_RELEASE` takes a release archive from GitHub
instead, and is how this repository goes back to a monthly release
once one holds `asm` templates.

Each build unpacks into its own directory in `$HOME`, about 220 MB,
and `/usr/local/bin/odin` is a symlink into the one in use. So a
second run of a build already on the machine only moves the symlink,
and going back to one you have had is as quick. Delete the directories
you do not want.

A nightly reports itself as `dev-2026-08-nightly:ec04cee`: the tag it
is past, and the commit it is at. The commit is the part that matters,
because the tag does not move between releases.

## From source instead

Only for a platform with no published archive, or a commit that no
nightly holds. It takes about five minutes and needs `llvm-18-dev` on
top of the packages above, because a compiler built here links LLVM
rather than carrying it.

```sh
GIT_LFS_SKIP_SMUDGE=1 git clone --depth 1 \
	https://github.com/odin-lang/Odin ~/odin
cd ~/odin && ./build_odin.sh release
```

The tip of master is what a nightly is cut from, so this is the same
compiler the script installs, built by hand.

`GIT_LFS_SKIP_SMUDGE` holds the LFS files as pointers, so the checkout
cannot fail on a binary this repository never links.

That leaves raylib to put in place. The pointer names the SHA-256 of
the library it stands for, and the LFS media host serves that library
to anyone:

```sh
cd ~/odin
git show HEAD:vendor/raylib/linux/libraylib.a          # the pointer, and the oid
curl -fL -o vendor/raylib/linux/libraylib.a \
	https://media.githubusercontent.com/media/odin-lang/Odin/master/vendor/raylib/linux/libraylib.a
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
