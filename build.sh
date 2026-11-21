#!/usr/bin/env bash
# Build goose-term with Goose's AOT C backend.
#
#   ./build.sh                 # build/goose-term
#   GOOSE=/path/to/goose ./build.sh
#
# The build compiles src/pty_helper.c alongside the generated C and links
# libutil for forkpty, plus the gfx/ui native parts (SDL3, Nuklear) that the
# goose_gfx package supplies.
set -euo pipefail
cd "$(dirname "$0")"

GOOSE="${GOOSE:-goose}"
if ! command -v "$GOOSE" >/dev/null 2>&1; then
    if [ -x ./goose-bin ]; then
        GOOSE=./goose-bin
    else
        echo "error: the goose compiler was not found." >&2
        echo "Install it (https://github.com/aardappel/goose) or set GOOSE=/path/to/goose." >&2
        exit 1
    fi
fi

mkdir -p build
"$GOOSE" build src/main.goose -o build/goose-term
echo "built build/goose-term"
