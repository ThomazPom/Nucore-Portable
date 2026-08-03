#!/bin/sh
# bundled.sh — portable launcher for 32-bit nucore/pinbox on x64 hosts.
#
# Wraps the target binary in a self-contained i386 runtime (../bundlex86)
# so the host needs no `dpkg --add-architecture i386` or system 32-bit libs.
#
# Usage: bundled.sh [--no-shim] [mode] <runner> <binary> [args...]
#   portable          — native SDL 1.2 + sigio_fix (default)
#   asix              — portable + ASIX libftchipid overlay
#   sdl12-compat      — experimental SDL 1.2 ABI on bundled SDL 2
#   sdl12-compat-asix — sdl12-compat + ASIX overlay
#
# This script is normally invoked by ../start.sh. Call it directly only for
# launcher development or to bypass start.sh's argument parser.

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd) || exit 1
BUNDLE=$(CDPATH= cd -- "$SCRIPT_DIR/../bundlex86" && pwd) || {
    echo "bundled.sh: cannot locate bundlex86/ relative to $SCRIPT_DIR" >&2
    exit 1
}
PRELOAD="$SCRIPT_DIR/sigio_fix.so"

set_library_path() {
    case "$1" in
        asix)              LIBPATH="$BUNDLE/asix:$BUNDLE/direct:$BUNDLE/indirect" ;;
        sdl12-compat)      LIBPATH="$BUNDLE/sdl12-compat:$BUNDLE/direct:$BUNDLE/indirect" ;;
        sdl12-compat-asix) LIBPATH="$BUNDLE/sdl12-compat:$BUNDLE/asix:$BUNDLE/direct:$BUNDLE/indirect" ;;
        *)                 LIBPATH="$BUNDLE/direct:$BUNDLE/indirect" ;;
    esac
}

# ── Wrap mode ──────────────────────────────────────────────────────────────────
# The runner binary (run / runrd / run_pb_rd) called execv() back into this
# script; re-exec the real emulator through the bundled ld-linux, re-applying
# --preload as a flag (env LD_PRELOAD is dropped across the runner→exec wrap).
if [ -n "$_BUNDLED_BINARY" ]; then
    set_library_path "$_BUNDLED_MODE"
    if [ "$_BUNDLED_USE_SHIM" = 0 ]; then
        echo "*** EXPERIMENT: sigio_fix.so is NOT loaded; RTC/SIGIO safety is unverified ***" >&2
        exec "$BUNDLE/indirect/ld-linux.so.2" \
            --inhibit-cache \
            --library-path "$LIBPATH" \
            "$_BUNDLED_BINARY" "$@"
    else
        exec "$BUNDLE/indirect/ld-linux.so.2" \
            --inhibit-cache \
            --preload "$PRELOAD" \
            --library-path "$LIBPATH" \
            "$_BUNDLED_BINARY" "$@"
    fi
fi

# ── Normal invocation ──────────────────────────────────────────────────────────
USE_SHIM=1
if [ "$1" = --no-shim ]; then
    USE_SHIM=0
    shift
fi

case "$1" in
    portable|asix|sdl12-compat|sdl12-compat-asix) MODE="$1"; shift ;;
    *)             MODE=portable ;;
esac

RUNNER="$1"; [ "$#" -gt 0 ] && shift
BINARY="$1"; [ "$#" -gt 0 ] && shift

if [ -z "$RUNNER" ] || [ -z "$BINARY" ]; then
    cat >&2 <<EOF
Usage: $0 [--no-shim] [mode] <runner> <binary> [args...]
  portable          — native SDL 1.2 + sigio_fix (default)
  asix              — portable + ASIX libftchipid overlay
  sdl12-compat      — experimental SDL 1.2 ABI on SDL 2
  sdl12-compat-asix — sdl12-compat + ASIX overlay
EOF
    exit 1
fi

case "$RUNNER" in /*) ;; *) RUNNER="$SCRIPT_DIR/$RUNNER" ;; esac
case "$BINARY" in /*) ;; *) BINARY="$SCRIPT_DIR/$BINARY" ;; esac

cd "$SCRIPT_DIR" || exit 1

export AUDIODEV="${AUDIODEV:-sysdefault}"
# Keep ALSA's dynamically loaded 32-bit PulseAudio modules inside the bundle.
# Without this override libasound uses its compiled-in multiarch directory
# (for example /usr/lib/i386-linux-gnu/alsa-lib), defeating portability.
export ALSA_PLUGIN_DIR="$BUNDLE/alsa-lib"

set_library_path "$MODE"

export _BUNDLED_MODE="$MODE"
export _BUNDLED_USE_SHIM="$USE_SHIM"
export _BUNDLED_BINARY="$BINARY"
exec "$BUNDLE/indirect/ld-linux.so.2" \
    --inhibit-cache \
    --library-path "$LIBPATH" \
    "$RUNNER" "$0" "$@"
