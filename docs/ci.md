# CI: everything built on hippo, Windows binaries cross-compiled

`.github/workflows/build.yml` builds the mod and the renderer on the self-hosted runners on hippo
(runner-hive, labels `[self-hosted, hippo]`), never on GitHub's runners. It runs on pushes to and
pull requests into master, and by hand (workflow_dispatch). The Windows binaries are
cross-compiled on Linux. Each job uploads an artifact laid out as it goes into a release, and
`bundle` turns them into the release archives. Nothing is published: a release takes the
`release` artifact's files as they are.

The repository is public, and a self-hosted runner would run whatever a fork's pull request
contains: every job has `if: github.event_name != 'pull_request' ||
github.event.pull_request.head.repo.full_name == github.repository`, so such pull requests do not run.

## Jobs

| job | what | artifact |
|---|---|---|
| hook | `stellar-injected.dll`, `stellar-loader.exe` (+ `.pdb`), `lua/` (with `pdxscript.lua`), `install.ps1`, `install.bat`, `uninstall.bat` | `stellarstellaris-hook-windows-x64` |
| proxy | `proxy/version.dll` (+ `.pdb`) | `stellarstellaris-proxy-windows-x64` |
| renderer-linux | `stellar-render` (`cargo build --release --locked` in `sim/render`) and its Lua tree | `stellar-render-linux-x64` |
| renderer-windows | `stellar-render.exe` (x86_64-pc-windows-gnullvm) and its Lua tree | `stellar-render-windows-x64` |
| bundle | the release archives, after the four above | `release` |

The hook and proxy artifacts together are the mod package's files (`proxy/version.dll` next to
the DLL, as `install.ps1` expects). Rough timings: see the end.

## Release layout

`bundle` writes, with `<version>` from `git describe --tags --always`:

- `stellarstellaris-<version>-windows-x64.zip`: the mod, as `install.bat` installs it
  (`stellar-injected.dll`, `stellar-loader.exe`, their `.pdb`, `proxy/version.dll` and `.pdb`,
  `lua/`, the install scripts);
- `stellar-render-<version>-linux-x64.tar.gz` and `stellar-render-<version>-windows-x64.zip`: the
  renderer and the Lua it reads, in the repository's layout: `stellar-render[.exe]`, `sim/lua/`,
  `sim/render/lua/`, `lua/`, `lib/stellar-lua-pdxscript/pdxscript.lua` (and its `LICENSE.txt`);
- `SHA256SUMS` of the three.

Each archive unpacks to a folder of its own name, with `LICENSE` and `VERSION`.
`tools/ci/package.sh` lays them out.

**Where the renderer finds its Lua.** `stellar_sim::runtime::repo_dir()` decides at run time:
`STELLAR_HOME` if set; else the executable's folder if it has `sim/lua/engine` (an unpacked
release); else the source tree it was built from (`cargo run` in a checkout). The renderer's own
Lua is `repo_dir()/sim/render/lua`. So an unpacked release runs from anywhere, and
`STELLAR_HOME=<checkout>` points a released binary at a working copy's Lua.

## Toolchains

They are in the runner image, at fixed paths; jobs download none
(`tools/ci/check-toolchains.sh` fails early, saying what is missing). The image is runner-hive's,
with `contrib/Dockerfile.windows-cross` (MattMills/runner-hive) layered on it. Every download is
pinned by version and SHA-256:

| | version | download | on disk |
|---|---|---|---|
| `/opt/llvm-mingw` | llvm-mingw 20260922, UCRT (LLVM 23.1.2), plus a `clang-cl` link | 84 MB | 617 MB |
| `/opt/xwin` | MSVC CRT 14.44.17.14, Windows SDK 10.0.26100 (VS 17.14.42 channel manifest), splatted by xwin 0.10.0 | 83 MB (+ xwin 3.4 MB) | 630 MB |
| `/usr/local/bin/ninja` | 1.13.2 | 0.1 MB | 0.3 MB |
| Rust targets | x86_64-pc-windows-msvc, x86_64-pc-windows-gnullvm (in the shared `RUSTUP_HOME`) | | 84 MB |

**llvm-mingw, not LLVM's release.** One 84 MB download has both kinds of Windows toolchain the
builds need: clang (as clang-cl), lld-link, llvm-lib and llvm-rc for the MSVC ABI with xwin, and
the MinGW-w64 headers, CRT and libunwind for Rust's gnullvm target. LLVM's Linux release is 2 GB
and has no MinGW runtime. The Ubuntu clang 18 of the base image is too old for the CRT's headers
(the STL wants clang 19), and unpinned.

**The hook and the proxy** must stay MSVC ABI with the MS CRT: they load into the MSVC-built game.
`cmake/toolchain-clang-cl-xwin.cmake` drives clang-cl as CMake drives MSVC: the same flags (`/EHsc`,
`/MD`, `/DWIN32 /D_WINDOWS`, RelWithDebInfo's `/Zi /O2 /Ob1`), SEH as MSVC compiles it, PDBs
from lld-link. There is no `mt`: lld-link embeds the default manifest itself, under the IDs `mt`
uses. Against the windows-latest build of 5802825, the cross-built files import the same DLLs
(but the loader does without `VCRUNTIME140_1`: clang uses the older C++ frame handler), export the
same names, and carry the same manifests. The CMake branches for MSVC and Unix are unchanged;
the cross one is taken only when cross-compiling from a Unix host:

- LuaJIT: `msvcbuild.bat` cannot run on Linux. `cmake/luajit-cross-msvc.cmake` runs its steps:
  `minilua` and `buildvm` built by the host's cc for a Windows x64 target (as LuaJIT's Makefile does
  for its cross builds), `buildvm -m peobj` writes `lj_vm.obj` (with the x64 unwind data) and the
  generated headers, clang-cl compiles `lj_*.c lib_*.c` with `msvcbuild.bat`'s flags and `/MD`,
  `llvm-lib` makes `lua51.lib`. A `luajit.exe` linked with it passed JIT, FFI (calls and callbacks)
  and error-unwinding checks (a Lua error out of a C callback) on Windows.
- The fnmatch engine (Rust staticlib) builds for x86_64-pc-windows-msvc: cargo runs through a
  wrapper (`cmake/cargo-cross-msvc.sh.in`) that has cc-rs compile its C dependency (zstd) with
  clang-cl and the toolchain's flags.

**The Windows renderer** is x86_64-pc-windows-gnullvm with llvm-mingw: mlua's vendored LuaJIT
(luajit-src) runs `msvcbuild.bat` for -msvc targets, and LuaJIT's Makefile for the others. The
renderer is a standalone program, so the MinGW ABI does not matter; its C runtime is still the
system's UCRT, and `crt-static` links libunwind in, so it needs only Windows' own DLLs (d3d12 is
loaded at run time). Its debug info (`debug = 1`: line tables) is DWARF inside the exe, as in
the Linux build.

**Caches.** The cargo registry is the runners' shared `CARGO_HOME`. The renderer jobs keep their
target directory in the runner slot's home (`~/.cache/stellarstellaris-ci/render`), so a run only
compiles what changed; the CMake jobs build from scratch each time (ExternalProject would not see a
LuaJIT submodule update).

## A cross build on your machine

On hippo, in the runner image, from a checkout with its submodules (the job user cannot write to
the share, so the build works on a copy):

```
docker run --rm -it -u runner -v "$PWD:/src:ro" --entrypoint bash runner-hive:latest
cp -R /src ~/w && cd ~/w
cmake -G Ninja -B build-win -DCMAKE_BUILD_TYPE=RelWithDebInfo -DCMAKE_TOOLCHAIN_FILE=cmake/toolchain-clang-cl-xwin.cmake
cmake --build build-win                     # build-win/stellar-injected.dll, proxy/version.dll, ...
```

Elsewhere, on Linux: unpack llvm-mingw, run `xwin --accept-license splat --output <dir>` (with
the versions above for the same result), `rustup target add x86_64-pc-windows-msvc
x86_64-pc-windows-gnullvm`, and pass `-DLLVM_ROOT=<llvm-mingw> -DXWIN_ROOT=<dir>` (or set them in
the environment) to the configure above. A Debug build also needs the debug CRT (`xwin splat
--include-debug-libs`).

The Windows renderer, from `sim/render`:

```
export CC_x86_64_pc_windows_gnullvm=/opt/llvm-mingw/bin/x86_64-w64-mingw32-clang
export CXX_x86_64_pc_windows_gnullvm=/opt/llvm-mingw/bin/x86_64-w64-mingw32-clang++
export AR_x86_64_pc_windows_gnullvm=/opt/llvm-mingw/bin/x86_64-w64-mingw32-ar
export CARGO_TARGET_X86_64_PC_WINDOWS_GNULLVM_LINKER=/opt/llvm-mingw/bin/x86_64-w64-mingw32-clang
export CARGO_TARGET_X86_64_PC_WINDOWS_GNULLVM_RUSTFLAGS="-C target-feature=+crt-static"
cargo build --release --locked --target x86_64-pc-windows-gnullvm
```

Then `bash tools/ci/package.sh render <binary> <dir>` lays out a package as CI does.

## Timings

Run 38543755762 (October 2026; a job's time from start to end, the checkout included). Cold: the
first run, with empty slots and none of the renderer's crates in the cargo registry. Warm: the
renderer's target directory already in the slot.

| job | cold | warm |
|---|---|---|
| hook | 57 s | 40-50 s (built from scratch each time: LuaJIT, the fnmatch engine, the DLL) |
| proxy | 23 s | 11 s |
| renderer-linux | 72 s | 16 s |
| renderer-windows | 60 s | 13 s |
| bundle | 28 s | 26 s |
| the run | 2 min 30 s | 1 min 10 s |

The repository gets two runner slots: the four build jobs run two at a time, then `bundle`.
