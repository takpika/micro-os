#!/bin/bash
# Xcode Cloud — build the userspace payload before the app is built.
#
# micro-os ships no programs in the app target: every program is a dylib built
# into payload/ by scripts/build-programs.sh, and the app's "Copy Payload" build
# phase bundles them. Xcode Cloud only checks out the repo (no payload/, and no
# private scripts/local/ recipes), so we (re)build a minimal *public* payload
# here — the system programs plus a couple of demo apps. lamia and any other
# scripts/local/ program never exist on CI, so they are never built.
#
# Runs once, right after the clone (network is available for the toybox fetch),
# which is before the app's xcodebuild — so payload/ is ready for Copy Payload.
set -euo pipefail

# Repo root. Xcode Cloud exports CI_PRIMARY_REPOSITORY_PATH; fall back to the
# parent of this script (ci_scripts/ lives at the repo root) for local runs.
REPO="${CI_PRIMARY_REPOSITORY_PATH:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$REPO"
echo "==> micro-os CI: building payload in $REPO"

# Demo apps to bundle. Defaults to a known-good minimal set (a console program
# and a vcocoa GUI app). Add more from `scripts/build-samples.sh --list`, but
# note TerminalProgram needs iOS 17 (onChange initial:) and vwin32-todo is
# unverified, so neither is included by default.
DEMOS="${MICRO_OS_CI_DEMOS:-demo-program vcocoa-todo}"

# Build both device + simulator slices so any workflow action (archive or test)
# finds its slice. Override with e.g. PLATFORMS=iphoneos for a device-only run.
export PLATFORMS="${PLATFORMS:-iphoneos iphonesimulator}"

# wm is built via `xcodebuild -target wm`, which does NOT resolve Swift packages
# on its own. Xcode Cloud hasn't resolved them yet at post-clone time, so resolve
# SwiftUIWindow up front (into the project's default DerivedData, which the wm
# build reuses) — otherwise the wm slice fails to link.
echo "==> micro-os CI: resolving Swift package dependencies"
xcrun xcodebuild -project micro-os.xcodeproj -resolvePackageDependencies

# System programs: init, wm, toybox. Building toybox also fetches the verified
# toybox tarball and regenerates payload/etc/setup-path (the boot provisioning,
# which globs $BUNDLE/*.dylib at boot, so it also covers the demos below).
echo "==> micro-os CI: building system programs (init, wm, toybox)"
scripts/build-system.sh

echo "==> micro-os CI: building demo programs ($DEMOS)"
# shellcheck disable=SC2086  # intentional word-splitting into program names
scripts/build-samples.sh $DEMOS

echo "==> micro-os CI: payload ready:"
ls -1 payload
