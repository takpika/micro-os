#!/bin/bash
# Xcode Cloud — build the userspace payload before the app is built.
#
# micro-os ships no programs in the app target: every program is a dylib built
# into payload/ by scripts/build-programs.sh, and the app's "Copy Payload" build
# phase bundles them. Xcode Cloud only checks out the repo (no payload/, and no
# private scripts/local/ recipes), so we (re)build a minimal *public* payload
# here — the system programs, public optional network tools, plus a couple of
# demo apps. Private scripts/local/ programs never exist on CI, so they are
# never built.
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

# This workflow archives for iOS device, so build only the iphoneos slice — the
# simulator slice would just double the (toybox) build time for nothing. If you
# add a simulator-based action (e.g. Test), set PLATFORMS="iphoneos iphonesimulator"
# in the workflow's environment variables.
export PLATFORMS="${PLATFORMS:-iphoneos}"

# toybox's build (scripts/portability.sh) uses `gsed` when present and otherwise
# falls back to BSD `sed` — but its generator scripts are GNU-sed-only, so the BSD
# fallback dies ("invalid command code"). macOS ships only BSD sed, so install GNU
# sed; toybox then auto-detects `gsed`. (build-programs.sh's own `sed -i ''` keeps
# using BSD /usr/bin/sed and is unaffected.)
if ! command -v gsed >/dev/null 2>&1; then
  echo "==> micro-os CI: installing GNU sed (toybox build prerequisite)"
  brew install gnu-sed
fi

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

echo "==> micro-os CI: building optional programs (curl, ifconfig, dig, nslookup, zip, unzip, whois, fastfetch)"
GROUP=optional scripts/build-programs.sh curl ifconfig bind-dns-tools zip unzip whois fastfetch

echo "==> micro-os CI: building demo programs ($DEMOS)"
# shellcheck disable=SC2086  # intentional word-splitting into program names
scripts/build-samples.sh $DEMOS

echo "==> micro-os CI: payload ready:"
ls -1 payload
