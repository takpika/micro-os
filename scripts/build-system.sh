#!/bin/bash
# Entry point for SYSTEM apps (init, wm). Thin wrapper over build-programs.sh.
#
#   scripts/build-system.sh            # build all system apps
#   scripts/build-system.sh init       # only this one
#   scripts/build-system.sh --list     # list system apps
#
# Honors the same env as build-programs.sh (e.g. PLATFORMS=iphonesimulator).
here="$(cd "$(dirname "$0")" && pwd)"
GROUP=system exec "$here/build-programs.sh" "$@"
