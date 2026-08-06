#!/bin/sh
# bundled.sh — portable launcher for 32-bit nucore/pinbox on x64 hosts.
#
# Wraps the target binary in a self-contained i386 runtime (../bundlex86)
# so the host needs no `dpkg --add-architecture i386` or system 32-bit libs.
#
# Usage: bundled.sh [--console] [--no-shim] [--no-audio-shim] [--no-sigio-shim] [mode] <runner> <binary> [args...]
#   portable          — native SDL 1.2 + sigio_fix (default)
#   asix              — experimental ASIX libftchipid 0.1.0 overlay
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
    export NUCORE_SHIM_AUDIO="$_BUNDLED_SHIM_AUDIO"
    export NUCORE_SHIM_SIGIO="$_BUNDLED_SHIM_SIGIO"
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
SHIM_AUDIO=1
SHIM_SIGIO=1
ALLOW_CONSOLE=0
while :; do
    case "$1" in
        --console)       ALLOW_CONSOLE=1; shift ;;
        --no-shim)       USE_SHIM=0; shift ;;
        --no-audio-shim) SHIM_AUDIO=0; shift ;;
        --no-sigio-shim) SHIM_SIGIO=0; shift ;;
        *) break ;;
    esac
done

console_refusal() {
    echo "bundled.sh: refusing direct console rendering: $1" >&2
    echo "Stop the display manager and every X11/Wayland session first." >&2
    exit 6
}

if [ "$ALLOW_CONSOLE" -eq 1 ]; then
    if command -v systemctl >/dev/null 2>&1 &&
       systemctl is-active --quiet display-manager.service 2>/dev/null; then
        console_refusal "display-manager.service is active"
    fi
    if command -v loginctl >/dev/null 2>&1 &&
       loginctl list-sessions --no-legend 2>/dev/null |
           while read -r sid _rest; do
               loginctl show-session "$sid" -p Type --value 2>/dev/null
           done | grep -Eq '^(x11|wayland|mir)$'; then
        console_refusal "a graphical logind session is active"
    fi
    if [ -d /tmp/.X11-unix ] &&
       find /tmp/.X11-unix -maxdepth 1 -type s -name 'X*' -print -quit 2>/dev/null | grep -q .; then
        console_refusal "an X server socket is present"
    fi
    export SDL_VIDEODRIVER=fbcon
    echo "*** DIRECT CONSOLE MODE: no scaling is provided ***" >&2
else
    if [ -z "${DISPLAY:-}" ]; then
        echo "bundled.sh: DISPLAY is not set; run from an X11 session." >&2
        echo "For intentional native fbcon output, use the gated --console mode." >&2
        exit 6
    fi
    export SDL_VIDEODRIVER=x11
fi

case "$1" in
    portable|asix|sdl12-compat|sdl12-compat-asix) MODE="$1"; shift ;;
    *)             MODE=portable ;;
esac

RUNNER="$1"; [ "$#" -gt 0 ] && shift
BINARY="$1"; [ "$#" -gt 0 ] && shift

if [ -z "$RUNNER" ] || [ -z "$BINARY" ]; then
    cat >&2 <<EOF
Usage: $0 [--console] [--no-shim] [--no-audio-shim] [--no-sigio-shim] [mode] <runner> <binary> [args...]
  portable          — native SDL 1.2 + sigio_fix (default)
  asix              — experimental ASIX libftchipid 0.1.0 overlay
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
export _BUNDLED_SHIM_AUDIO="$SHIM_AUDIO"
export _BUNDLED_SHIM_SIGIO="$SHIM_SIGIO"
export _BUNDLED_BINARY="$BINARY"
exec "$BUNDLE/indirect/ld-linux.so.2" \
    --inhibit-cache \
    --library-path "$LIBPATH" \
    "$RUNNER" "$0" "$@"
