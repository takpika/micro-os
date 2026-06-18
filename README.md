# micro-os

A tiny operating-system-style runtime for iOS, written in SwiftUI. The app is a
**kernel + SDK** — it ships no programs of its own. Userspace programs (including
the system apps) are built separately as dylibs and loaded at runtime into a
single shared address space, each running on its own pthread.

> ⚠️ Educational / hobby project. "Processes" are pthreads in one address space,
> not isolated OS processes — there is no memory protection between them.

## How it works

- **Programs are dylibs.** Each exports `int entry(int argc, char **argv)` and is
  loaded by the kernel into the app's address space. A "process" is the pthread
  running that dylib; its PID lives in pthread TLS, so host calls like
  `micro_os_stdout()` know who is calling without being passed a PID.
- **CRT shims** (`crt/`) redirect `printf` / `write` / `exit` / `fork` / `execv`
  and friends to the kernel before they reach the platform libc, so ordinary C
  compiled with `-include micro_os_crt.h` works against the console out of the box.
- **PID-routed I/O.** stdin/stdout/stderr, pseudo-TTYs, a service registry, and
  process-exit observers are all keyed by PID and cleaned up automatically on exit.
- **Compatibility runtimes.** A GUI program links a runtime + shim into its dylib:
  `vcocoa` (AppKit → UIKit) or `vwin32` (Win32). The runtime's `entry` then calls
  the program's renamed `main` / `WinMain`.
- **Window manager.** `wm` (a dylib backed by the SwiftUIWindow package) hosts
  program windows; the kernel itself only keeps a generic service-table pointer.

## Layout

| Path | What |
|---|---|
| `micro-os/` | the app — kernel, dylib loader / host ABI, console UI |
| `apps/` | system app source: `init` (PID 1, C) and `wm` (window manager) |
| `runtimes/` | compatibility runtimes: `vcocoa` (AppKit), `vwin32` (Win32) |
| `crt/`, `include/` | shared runtime core + headers / SDK linked into every program |
| `samples/` | example programs |
| `scripts/` | build & provisioning scripts |
| `payload/` | container image — built dylibs land here and get bundled (local, git-ignored) |

## Build & run

1. **Provision userspace** — build programs into `payload/` as `.xcframework`s
   (one slice per platform, so device + simulator coexist and `payload/` is built
   only once):

   ```sh
   scripts/build-system.sh      # system apps (init, wm)
   scripts/build-samples.sh     # sample programs
   GROUP=optional scripts/build-programs.sh curl  # optional programs (curl)
   # faster sim-only: PLATFORMS=iphonesimulator scripts/build-system.sh
   ```

2. **Build & run the app** in Xcode (`micro-os.xcodeproj`, scheme `micro-os`).
   Its *Copy Payload* phase extracts the slice matching the build target into
   `BundledDylibs/` and signs it. On launch the kernel boots `init` (PID 1) and
   the console comes up; launch programs from there (e.g. `wm &`).

See **[samples/README.md](samples/README.md)** for the full host ABI / SDK and how
to build C, Swift, vcocoa, and vwin32 programs by hand, and
**[payload/README.md](payload/README.md)** for the container-image layout.

## Private programs

Programs that must not be committed are built via drop-in recipes under
`scripts/local/*.sh` (git-ignored): define `build_<name>()` and append `<name>`
to `LOCAL_PROGRAMS`. `build-programs.sh` sources them automatically, so they join
the `all` / `local` groups without ever touching a tracked file.

## Dependencies

- `wm` uses the [SwiftUIWindow](https://github.com/takpika/swiftui-window) Swift
  package (resolved by Xcode).
- `toybox` is built from upstream into a single dylib for the shell utilities.
