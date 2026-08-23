#!/bin/sh
# bundled.sh — portable launcher for 32-bit nucore/pinbox on x64 hosts.
#
# Wraps the target binary in a self-contained i386 runtime (../bundlex86)
# so the host needs no `dpkg --add-architecture i386` or system 32-bit libs.
#
# Usage: bundled.sh [--console] [--no-runner] [--wayland|--xwayland|--kmsdrm] [--no-shim] [--no-audio-shim] [--no-sigio-shim] [mode] <runner> <binary> [args...]
#   portable          — native SDL 1.2 + sigio_fix (default)
#   asix              — experimental ASIX libftchipid 0.1.0 overlay
#   sdl12-compat      — experimental SDL 1.2 ABI on bundled SDL 2
#   sdl12-compat-asix — sdl12-compat + ASIX overlay
#
# This script is normally invoked by ../start.sh. Call it directly only for
# launcher development or to bypass start.sh's argument parser.

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd) || exit 1
SELF="$SCRIPT_DIR/$(basename -- "$0")"
BUNDLE=$(CDPATH= cd -- "$SCRIPT_DIR/../bundlex86" && pwd) || {
    echo "bundled.sh: cannot locate bundlex86/ relative to $SCRIPT_DIR" >&2
    exit 1
}
PRELOAD="$SCRIPT_DIR/sigio_fix.so"
WAYLAND_MESA="$BUNDLE/optional/wayland-mesa-i386"

set_library_path() {
    case "$1" in
        asix)              LIBPATH="$BUNDLE/asix:$BUNDLE/direct:$BUNDLE/indirect" ;;
        sdl12-compat)      LIBPATH="$BUNDLE/sdl12-compat:$BUNDLE/direct:$BUNDLE/indirect" ;;
        sdl12-compat-asix) LIBPATH="$BUNDLE/sdl12-compat:$BUNDLE/asix:$BUNDLE/direct:$BUNDLE/indirect" ;;
        *)                 LIBPATH="$BUNDLE/direct:$BUNDLE/indirect" ;;
    esac
    case "$1" in
        sdl12-compat|sdl12-compat-asix)
            if { [ "${SDL_VIDEODRIVER:-}" = wayland ] ||
                 [ "${SDL_VIDEODRIVER:-}" = KMSDRM ]; } &&
               [ "${SDL_RENDER_DRIVER:-}" != software ]; then
                if ! "$SCRIPT_DIR/wayland-mesa.sh" check; then
                    echo "bundled.sh: SDL2 ${SDL_VIDEODRIVER} needs the optional Mesa i386 pack." >&2
                    echo "Install it with: $SCRIPT_DIR/wayland-mesa.sh install" >&2
                    echo "Or use a hosted X11/Xwayland path, which does not need this pack." >&2
                    exit 6
                fi
                LIBPATH="$WAYLAND_MESA/indirect:$LIBPATH"
                export LIBGL_DRIVERS_PATH="${LIBGL_DRIVERS_PATH:-$WAYLAND_MESA/dri}"
                export __EGL_VENDOR_LIBRARY_FILENAMES="${__EGL_VENDOR_LIBRARY_FILENAMES:-$WAYLAND_MESA/egl_vendor.d/50_mesa.json}"
            fi
            ;;
    esac
}

# ── Wrap mode ──────────────────────────────────────────────────────────────────
# The runner binary (run / runrd / run_pb_rd) called execv() back into this
# script; re-exec the real emulator through the bundled ld-linux, re-applying
# --preload as a flag (env LD_PRELOAD is dropped across the runner→exec wrap).
if [ -n "$_BUNDLED_BINARY" ]; then
    set_library_path "$_BUNDLED_MODE"
    EXTRA_PRELOAD=""
    case "$_BUNDLED_MODE:${SDL_VIDEODRIVER:-}:${WAYLAND_DISPLAY:-}" in
        sdl12-compat:x11:*|sdl12-compat-asix:x11:*) ;;
        sdl12-compat:*:?*|sdl12-compat-asix:*:?*)
            EXTRA_PRELOAD=":$SCRIPT_DIR/sdl12_wayland_fix.so"
            ;;
    esac
    export NUCORE_SHIM_AUDIO="$_BUNDLED_SHIM_AUDIO"
    export NUCORE_SHIM_SIGIO="$_BUNDLED_SHIM_SIGIO"
    if [ "$_BUNDLED_USE_SHIM" = 0 ]; then
        echo "*** EXPERIMENT: sigio_fix.so is NOT loaded; RTC/SIGIO safety is unverified ***" >&2
        if [ -n "$EXTRA_PRELOAD" ]; then
            exec "$BUNDLE/indirect/ld-linux.so.2" \
                --inhibit-cache \
                --preload "${EXTRA_PRELOAD#:}" \
                --library-path "$LIBPATH" \
                "$_BUNDLED_BINARY" "$@"
        else
            exec "$BUNDLE/indirect/ld-linux.so.2" \
                --inhibit-cache \
                --library-path "$LIBPATH" \
                "$_BUNDLED_BINARY" "$@"
        fi
    else
        exec "$BUNDLE/indirect/ld-linux.so.2" \
            --inhibit-cache \
            --preload "$PRELOAD$EXTRA_PRELOAD" \
            --library-path "$LIBPATH" \
            "$_BUNDLED_BINARY" "$@"
    fi
fi

# ── Normal invocation ──────────────────────────────────────────────────────────
USE_SHIM=1
SHIM_AUDIO=1
SHIM_SIGIO=1
ALLOW_CONSOLE=0
NO_RUNNER=0
SDL_DISPLAY=auto
while :; do
    case "$1" in
        --console)       ALLOW_CONSOLE=1; shift ;;
        --no-runner)     NO_RUNNER=1; shift ;;
        --wayland)       SDL_DISPLAY=wayland; shift ;;
        --xwayland)      SDL_DISPLAY=xwayland; shift ;;
        --kmsdrm)        SDL_DISPLAY=kmsdrm; shift ;;
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
    echo "*** DIRECT CONSOLE MODE: SDL will select an available direct-display backend ***" >&2
else
    if [ -z "${DISPLAY:-}" ] && [ -z "${WAYLAND_DISPLAY:-}" ]; then
        echo "bundled.sh: no X11 or Wayland display is available." >&2
        echo "For intentional direct display, use the gated --console mode." >&2
        exit 6
    fi
fi

case "$1" in
    portable|asix|sdl12-compat|sdl12-compat-asix) MODE="$1"; shift ;;
    *)             MODE=portable ;;
esac

if [ "$SDL_DISPLAY" != auto ]; then
    case "$MODE" in
        sdl12-compat|sdl12-compat-asix) ;;
        *) echo "bundled.sh: --$SDL_DISPLAY requires sdl12-compat" >&2; exit 2 ;;
    esac
fi
case "$SDL_DISPLAY" in
    wayland)
        [ -n "${WAYLAND_DISPLAY:-}" ] || {
            echo "bundled.sh: --wayland requires a Wayland display" >&2; exit 6;
        }
        export SDL_VIDEODRIVER=wayland
        export SDL_RENDER_DRIVER="${SDL_RENDER_DRIVER:-opengles2}"
        export SDL_VIDEO_WAYLAND_ALLOW_LIBDECOR="${SDL_VIDEO_WAYLAND_ALLOW_LIBDECOR:-0}"
        ;;
    xwayland)
        [ -n "${DISPLAY:-}" ] || {
            echo "bundled.sh: --xwayland requires an X11/Xwayland display" >&2; exit 6;
        }
        export SDL_VIDEODRIVER=x11
        ;;
    kmsdrm)
        [ "$ALLOW_CONSOLE" -eq 1 ] || {
            echo "bundled.sh: --kmsdrm requires the gated --console mode" >&2; exit 6;
        }
        unset DISPLAY XAUTHORITY WAYLAND_DISPLAY
        export SDL_VIDEODRIVER=KMSDRM
        ;;
esac

RUNNER="$1"; [ "$#" -gt 0 ] && shift
BINARY="$1"; [ "$#" -gt 0 ] && shift

if [ -z "$RUNNER" ] || [ -z "$BINARY" ]; then
    cat >&2 <<EOF
Usage: $0 [--console] [--no-runner] [--wayland|--xwayland|--kmsdrm] [--no-shim] [--no-audio-shim] [--no-sigio-shim] [mode] <runner> <binary> [args...]
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

# An elevated manual launch must not claim the desktop user's runtime as
# root's XDG_RUNTIME_DIR. Keep only explicit addresses for user services and,
# when present, expose the validated Wayland socket in a private root runtime.
ROOT_SESSION_RUNTIME=""
cleanup_root_session_runtime() {
    [ -n "$ROOT_SESSION_RUNTIME" ] || return 0
    rmdir "$ROOT_SESSION_RUNTIME/pulse" 2>/dev/null || true
    rm -f "$ROOT_SESSION_RUNTIME/wayland-client"
    rmdir "$ROOT_SESSION_RUNTIME" 2>/dev/null || true
}
if [ "$(id -u)" -eq 0 ] && [ -n "${XDG_RUNTIME_DIR:-}" ]; then
    runtime_owner=$(stat -c %u "$XDG_RUNTIME_DIR" 2>/dev/null || true)
    case "$XDG_RUNTIME_DIR:$runtime_owner" in
        /run/user/[0-9]*:[1-9]*)
            user_runtime=$XDG_RUNTIME_DIR
            [ ! -S "$user_runtime/bus" ] ||
                export DBUS_SESSION_BUS_ADDRESS="unix:path=$user_runtime/bus"
            [ ! -S "$user_runtime/pulse/native" ] ||
                export PULSE_SERVER="unix:$user_runtime/pulse/native"

            if [ "${SDL_VIDEODRIVER:-}" = x11 ] && [ -d /run/user/0 ] &&
               [ "$(stat -c %u /run/user/0 2>/dev/null)" = 0 ]; then
                XDG_RUNTIME_DIR=/run/user/0
                export XDG_RUNTIME_DIR
            else
                ROOT_SESSION_RUNTIME=$(mktemp -d /run/nucore-session.XXXXXX) || exit 1
                chmod 0700 "$ROOT_SESSION_RUNTIME"
                case "${WAYLAND_DISPLAY:-}" in
                "") ;;
                */*|.|..)
                    cleanup_root_session_runtime
                    echo "bundled.sh: invalid WAYLAND_DISPLAY" >&2
                    exit 6
                    ;;
                *)
                wayland_socket="$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY"
                if [ -S "$wayland_socket" ] &&
                   [ "$(stat -c %u "$wayland_socket" 2>/dev/null)" = "$runtime_owner" ]; then
                    ln -s "$wayland_socket" "$ROOT_SESSION_RUNTIME/wayland-client" || {
                        cleanup_root_session_runtime; exit 1;
                    }
                    WAYLAND_DISPLAY=wayland-client
                    export WAYLAND_DISPLAY
                elif [ "${SDL_VIDEODRIVER:-}" = wayland ]; then
                    cleanup_root_session_runtime
                    echo "bundled.sh: invalid Wayland socket" >&2
                    exit 6
                fi
                ;;
                esac
                XDG_RUNTIME_DIR="$ROOT_SESSION_RUNTIME"
                export XDG_RUNTIME_DIR
            fi
            ;;
    esac
fi

[ -z "$ROOT_SESSION_RUNTIME" ] || trap 'cleanup_root_session_runtime; exit 130' HUP INT TERM

if [ "$NO_RUNNER" -eq 1 ]; then
    if [ -z "$ROOT_SESSION_RUNTIME" ]; then
        exec "$SELF" "$@"
    fi
    status=0
    "$SELF" "$@" || status=$?
elif [ -n "$ROOT_SESSION_RUNTIME" ]; then
    status=0
    "$BUNDLE/indirect/ld-linux.so.2" \
        --inhibit-cache \
        --library-path "$LIBPATH" \
        "$RUNNER" "$SELF" "$@" || status=$?
else
    exec "$BUNDLE/indirect/ld-linux.so.2" \
        --inhibit-cache \
        --library-path "$LIBPATH" \
        "$RUNNER" "$SELF" "$@"
fi

trap - HUP INT TERM
cleanup_root_session_runtime
exit "$status"
