# microOS programs

The app is just a **kernel + SDK** — it compiles no programs. Every program
(system apps *and* samples) is built into `payload/` by a script, and the app's
build step copies `payload/` into the bundle. Think container: the app is the
runtime, `payload/` is the image you provision. There are **no per-app Xcode
targets** — system apps and samples are built the exact same way.

## Project layout

- `apps/` — **system app** source: `init` (PID 1, plain C) and `wm` (window
  manager). `wm` is an Xcode `wm` target that uses the SwiftUIWindow SPM package;
  the build script builds it with `xcodebuild` per platform (the app target
  itself never builds it).
- `runtimes/` — **compatibility runtimes (SDKs)**: `vcocoa` (AppKit), `vwin32`
  (Win32). Not apps; compiled *into* a GUI program's dylib.
- `samples/` — example programs (this folder).
- `crt/`, `include/` — shared runtime core used by every program.
- `payload/` — where built dylibs land and get bundled (git-ignored, local).

## Building programs

The build scripts compile programs into `payload/` as **`.xcframework`s** — one
slice per platform (`iphoneos` + `iphonesimulator`). There are two entry points
over a shared engine (`scripts/build-programs.sh`):

```sh
scripts/build-system.sh             # system apps (init, wm)
scripts/build-samples.sh            # sample programs
scripts/build-system.sh init        # a subset
scripts/build-system.sh --list      # list that group
```

Because each `.xcframework` carries **both** the device and simulator slice, you
build `payload/` **once** — switching the app between device and simulator needs
no rebuild. The app's `Copy Payload` phase extracts the slice matching the build
target (`$PLATFORM_NAME`) as a flat `BundledDylibs/<name>.dylib` and signs it;
non-xcframework files (config, subfolders) are mirrored as-is.

For a faster sim-only build, limit the platforms:
`PLATFORMS=iphonesimulator scripts/build-programs.sh init`.

`payload/` keeps only `README.md` + `.gitignore` in git; built `.xcframework`s
and your local config (e.g. `etc/init.conf`) are ignored. An empty `payload/` is
an empty container.

## Building a program by hand

The script just wraps `clang`/`swiftc`. The plain-C case, for reference:

```sh
clang -c -I include crt/micro_os_crt.c -o /tmp/micro_os_crt.o
clang -c -I include crt/micro_os_libc_shim.c -o /tmp/micro_os_libc_shim.o
clang -dynamiclib -undefined dynamic_lookup -I include -include micro_os_crt.h samples/demo-program.c /tmp/micro_os_crt.o /tmp/micro_os_libc_shim.o -o /tmp/demo-program.dylib
```

The dylib exports:

```c
int entry(int argc, char **argv);
```

The host exports these process-aware functions. They do not require the dylib to pass PID; the host reads PID from pthread TLS.

```c
int32_t micro_os_pid(void);
void micro_os_stdout(const char *text);
void micro_os_stderr(const char *text);
int32_t micro_os_stdin(char *buffer, int32_t maxBytes);
void micro_os_overlay_platform_view_fullscreen(void *retainedPlatformView);
void micro_os_overlay_platform_view(void *retainedPlatformView, double x, double y, double width, double height);
void micro_os_kernel_panic(const char *text);
void micro_os_service_register(const char *name, void *serviceTable);
void *micro_os_service_lookup(const char *name);
void micro_os_process_observe_exit(void (*callback)(int32_t pid, void *context), void *context);
int32_t micro_os_ptty_create(const char *name);
void micro_os_ptty_write(int32_t id, const char *text);
void micro_os_ptty_input(int32_t id, const char *text);
int32_t micro_os_ptty_read(int32_t id, char *buffer, int32_t maxBytes);
void micro_os_ptty_observe_output(int32_t id, void (*callback)(int32_t id, const char *text, void *context), void *context);
void micro_os_process_keep_alive(void);
```

For ordinary C code, compile user sources with `-include micro_os_crt.h`. That redirects console output and unavailable process calls such as `printf`, `puts`, `write(1/2, ...)`, `exit`, `fork`, and `execv` to the custom CRT shim before they reach iOS/macOS libc.

`exit(status)` is process-local: it records the current microOS PID as exited and terminates the pthread running that dylib. It does not terminate the host app.

Filesystem calls that iOS already supports should keep using the native libc path. The CRT shim only captures `FILE *`/fd output when it targets `stdout` or `stderr`; `fprintf(file, ...)`, `fwrite(file, ...)`, and `write(fileFd, ...)` fall back to the platform libc implementation. The shared libc shim in `crt/micro_os_libc_shim.c` also covers fd duplication, `isatty`, basic `termios`, `waitpid`, and exec-style spawn paths for programs that need TTY behavior.

Compile `crt/micro_os_crt.c` and `crt/micro_os_libc_shim.c` separately without `-include micro_os_crt.h`, then link those objects into the dylib.

Swift dylibs can mount a real SwiftUI view by wrapping it in a platform hosting view and passing a retained pointer to the host:

```sh
CLANG_MODULE_CACHE_PATH=/tmp/micro-os-clang-cache \
swiftc -emit-library -parse-as-library samples/SwiftOverlayProgram.swift \
  -module-name SwiftOverlayProgram \
  -Xlinker -undefined -Xlinker dynamic_lookup \
  -o /tmp/SwiftOverlayProgram.dylib
```

Compile `include/MicroOS.swift` into the Swift dylib alongside your program (pass it as an extra source to `swiftc`). It provides `MicroOS.stdout(...)`, `MicroOS.stderr(...)`, `MicroOS.overlayFullscreen(...)`, `MicroOS.overlay(...)`, `MicroOS.keepAlive()`, `MicroOS.spawn(...)`, and `MicroOS.exit(...)` instead of writing raw `@_silgen_name` bindings in each program. `MicroOS.keepAlive()` blocks until the host requests process termination, then returns so `entry` can finish normally.

On macOS the sample uses `NSHostingView`. On iOS, use `UIHostingController(rootView: YourView()).view`. Pass the retained platform view pointer to `micro_os_overlay_platform_view_fullscreen` for a full-console overlay, or to `micro_os_overlay_platform_view` when you want explicit placement.

## Building vcocoa / vwin32 GUI apps

`runtimes/vcocoa` and `runtimes/vwin32` are compatibility runtimes, not
standalone programs. You build a GUI app by compiling the runtime, its shim, the
shared core, and **your** GUI source into a single dylib. The runtime's `entry`
then calls your program's renamed `main`/`WinMain`.

### vcocoa (AppKit-compatible)

```sh
# shared core
clang -c -I include crt/micro_os_crt.c        -o /tmp/crt.o
clang -c -I include crt/micro_os_libc_shim.c  -o /tmp/libc.o
clang -c -I include crt/micro_os_gui_shim.c   -o /tmp/gui.o
# AppKit shim (the vcocoa runtime, ObjC)
clang -c -fobjc-arc -DMICRO_OS_APPKIT_SHIM=1 -I include -I runtimes/vcocoa/include \
  runtimes/vcocoa/micro_os_appkit_shim.m -o /tmp/appkit.o
# your AppKit app — main is renamed so the runtime can invoke it
clang -c -fobjc-arc -DMICRO_OS_APPKIT_SHIM=1 -I include -I runtimes/vcocoa/include \
  -Dmain=micro_os_appkit_user_main -include micro_os_crt.h \
  samples/vcocoa-todo.m -o /tmp/app.o
# link runtime + interface + objects into one dylib
swiftc -emit-library -parse-as-library \
  include/MicroOS.swift runtimes/vcocoa/VCocoaRuntime.swift \
  /tmp/app.o /tmp/crt.o /tmp/libc.o /tmp/gui.o /tmp/appkit.o \
  -module-name vcocoaTodo -Xlinker -undefined -Xlinker dynamic_lookup \
  -o payload/vcocoaTodo.dylib
```

### vwin32 (Win32-compatible)

```sh
# shared core (same /tmp/crt.o, /tmp/libc.o, /tmp/gui.o as above)
# Win32 shim (the vwin32 runtime, C)
clang -c -DMICRO_OS_WIN32_SHIM=1 -I include -I runtimes/vwin32/include \
  runtimes/vwin32/micro_os_win32_shim.c -o /tmp/win32.o
# your Win32 app — WinMain is renamed so the runtime can invoke it
clang -c -DMICRO_OS_WIN32_SHIM=1 -I include -I runtimes/vwin32/include \
  -DWinMain=micro_os_win32_user_main -include micro_os_crt.h \
  samples/vwin32-todo.c -o /tmp/app.o
swiftc -emit-library -parse-as-library \
  include/MicroOS.swift runtimes/vwin32/VWin32Runtime.swift \
  /tmp/app.o /tmp/crt.o /tmp/libc.o /tmp/gui.o /tmp/win32.o \
  -module-name vwin32Todo -Xlinker -undefined -Xlinker dynamic_lookup \
  -o payload/vwin32Todo.dylib
```

The commands above target the host (macOS). To bundle a GUI app for the iOS
Simulator, add the matching `-isysroot`/`-target` (clang) and `-sdk`/`-target`
(swiftc) flags so the dylib matches the app's platform.

The kernel exposes a generic service registry and process-exit observer. WM-specific behavior should live in `wm.dylib`; the kernel only stores a service table pointer and removes it automatically when the owning process exits. The reserved WM service name used by the Swift helper is `micro-os.wm.v1`.

Pseudo TTYs are created with `micro_os_ptty_create`. Output observers are automatically removed when the observing process exits.
