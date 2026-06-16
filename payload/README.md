# payload/

This is the container image. At app build time `scripts/copy-payload.sh` copies
it into `Resources/BundledDylibs/` — nothing is compiled. Build files in with
`scripts/build-programs.sh` (see `samples/README.md`).

## What to put here

- `<name>.xcframework` — a program built for both platforms (device +
  simulator). The build step extracts the slice matching the target as a flat
  `<name>.dylib`. This is what `scripts/build-programs.sh` produces.
- `<name>.dylib` — a single-platform program, copied as-is (you manage matching
  the app's platform yourself — e.g. a prebuilt `busybox.dylib`).
- `manifest.txt` — optional. One `<name>.dylib` per line; the kernel also
  discovers dylibs by listing the folder, so this is usually unnecessary.
- Subfolders (e.g. `etc/init.conf`) — copied as-is; the tree is preserved.

## Git

Everything you drop here is **local** (git-ignored) — built `.xcframework`s,
config, your local userspace. Only this `README.md` + `.gitignore` are committed
so the folder exists in the repo. See `payload/.gitignore`.
