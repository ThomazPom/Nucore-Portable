#!/bin/sh
# bundled.sh — portable launcher for 32-bit nucore/pinbox on x64 hosts.
#
# Wraps the target binary in a self-contained i386 runtime (../bundlex86)
# so the host needs no `dpkg --add-architecture i386` or system 32-bit libs.
#
# Usage: bundled.sh [portable|asix] <runner> <binary> [args...]
#   portable  — bundled ld-linux + sigio_fix preload         (default)
#   asix      — portable + ASIX libftchipid overlay (USB-to-serial cabinets)
#
# This script is normally invoked by ../start.sh; you only need to call it
# directly for ASIX mode or to bypass the start.sh argument parser.

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd) || exit 1
BUNDLE=$(CDPATH= cd -- "$SCRIPT_DIR/../bundlex86" && pwd) || {
    echo "bundled.sh: cannot locate bundlex86/ relative to $SCRIPT_DIR" >&2
    exit 1
}
PRELOAD="$SCRIPT_DIR/sigio_fix.so"

# ── Wrap mode ──────────────────────────────────────────────────────────────────
# The runner binary (run / runrd / run_pb_rd) called execv() back into this
# script; re-exec the real emulator through the bundled ld-linux, re-applying
# --preload as a flag (env LD_PRELOAD is dropped across the runner→exec wrap).
if [ -n "$_BUNDLED_BINARY" ]; then
    case "$_BUNDLED_MODE" in
        asix) LIBPATH="$BUNDLE/asix:$BUNDLE/direct:$BUNDLE/indirect" ;;
        *)    LIBPATH="$BUNDLE/direct:$BUNDLE/indirect" ;;
    esac
    exec "$BUNDLE/indirect/ld-linux.so.2" \
        --inhibit-cache \
        --preload "$PRELOAD" \
        --library-path "$LIBPATH" \
        "$_BUNDLED_BINARY" "$@"
fi

# ── Normal invocation ──────────────────────────────────────────────────────────
case "$1" in
    portable|asix) MODE="$1"; shift ;;
    *)             MODE=portable ;;
esac

RUNNER="$1"; [ "$#" -gt 0 ] && shift
BINARY="$1"; [ "$#" -gt 0 ] && shift

if [ -z "$RUNNER" ] || [ -z "$BINARY" ]; then
    cat >&2 <<EOF
Usage: $0 [portable|asix] <runner> <binary> [args...]
  portable  — bundled ld-linux + sigio_fix (default)
  asix      — portable + ASIX libftchipid overlay
EOF
    exit 1
fi

case "$RUNNER" in /*) ;; *) RUNNER="$SCRIPT_DIR/$RUNNER" ;; esac
case "$BINARY" in /*) ;; *) BINARY="$SCRIPT_DIR/$BINARY" ;; esac

cd "$SCRIPT_DIR" || exit 1

export AUDIODEV="${AUDIODEV:-sysdefault}"

case "$MODE" in
    asix) LIBPATH="$BUNDLE/asix:$BUNDLE/direct:$BUNDLE/indirect" ;;
    *)    LIBPATH="$BUNDLE/direct:$BUNDLE/indirect" ;;
esac

export _BUNDLED_MODE="$MODE"
export _BUNDLED_BINARY="$BINARY"
exec "$BUNDLE/indirect/ld-linux.so.2" \
    --inhibit-cache \
    --library-path "$LIBPATH" \
    "$RUNNER" "$0" "$@"
