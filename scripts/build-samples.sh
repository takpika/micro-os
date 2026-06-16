#!/bin/bash
# Entry point for SAMPLE programs. Thin wrapper over build-programs.sh.
#
#   scripts/build-samples.sh                 # build all samples
#   scripts/build-samples.sh demo-program    # only this one
#   scripts/build-samples.sh --list          # list samples
#
# Honors the same env as build-programs.sh (e.g. PLATFORMS=iphonesimulator).
here="$(cd "$(dirname "$0")" && pwd)"
GROUP=samples exec "$here/build-programs.sh" "$@"
