#!/bin/bash
# Dedicated cabinet session: one minimal Xorg server, one Nucore client, no
# display manager or desktop environment. Called by nucore.service on tty1.

set -e

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)

if [ "${1:-}" = --client ]; then
    shift
    case " $* " in
        *" --sdl12-compat "*)
            if [ -x "$ROOT_DIR/bin/nucore-wm" ]; then
                "$ROOT_DIR/bin/nucore-wm" &
                WM_PID=$!
                # Wait until the EWMH ownership marker is visible to SDL2.
                i=0
                while [ "$i" -lt 50 ]; do
                    "$ROOT_DIR/bin/nucore-wm" --ready 2>/dev/null && break
                    kill -0 "$WM_PID" 2>/dev/null || {
                        echo "nucore-xorg-only: nucore-wm failed to start" >&2
                        wait "$WM_PID" 2>/dev/null || true
                        exit 4
                    }
                    i=$((i + 1))
                    sleep 0.02
                done
                if [ "$i" -ge 50 ]; then
                    echo "nucore-xorg-only: nucore-wm readiness timeout" >&2
                    kill "$WM_PID" 2>/dev/null || true
                    wait "$WM_PID" 2>/dev/null || true
                    exit 4
                fi
            fi
            ;;
    esac
    # xinit supplies DISPLAY and XAUTHORITY. Force both SDL implementations
    # through X11 so native SDL and sdl12-compat share the proven path.
    # xinit puts its client in a separate process group.  Leaving stdin on the
    # service's controlling tty makes the legacy runner read from tty1 as a
    # background group, so the kernel suspends it with SIGTTIN before SDL can
    # create a window. Keyboard input is delivered by X11; detach terminal
    # input while keeping stdout/stderr in the journal.
    STATUS=0
    env SDL_VIDEODRIVER=x11 \
        "$ROOT_DIR/start.sh" --no-root --no-inhibit "$@" </dev/null || STATUS=$?
    if [ -n "${WM_PID:-}" ]; then
        kill "$WM_PID" 2>/dev/null || true
        wait "$WM_PID" 2>/dev/null || true
    fi
    exit "$STATUS"
fi

OPEN_MAINTENANCE=1

administrative_stop() {
    # systemd sends TERM when the service is stopped for maintenance,
    # uninstall or shutdown.  That is not a player leaving Nucore, so do not
    # race the shutdown by starting a display manager.
    OPEN_MAINTENANCE=0
    exit 0
}

maintenance_fallback() {
    [ "$OPEN_MAINTENANCE" -eq 1 ] || return 0
    case "${NUCORE_MAINTENANCE:-display-manager}" in
        display-manager)
            echo "[nucore-xorg-only] Nucore/Xorg exited; starting display manager" >&2
            if systemctl cat display-manager.service >/dev/null 2>&1; then
                systemctl --no-block start graphical.target display-manager.service || true
            else
                echo "[nucore-xorg-only] no display manager; falling back to tty1 login" >&2
                systemctl --no-block start getty@tty1.service || true
            fi
            ;;
        getty)
            echo "[nucore-xorg-only] Nucore/Xorg exited; starting tty1 login" >&2
            systemctl --no-block start getty@tty1.service || true
            ;;
        none)
            echo "[nucore-xorg-only] Nucore/Xorg exited; maintenance fallback disabled" >&2
            ;;
        *)
            echo "[nucore-xorg-only] invalid NUCORE_MAINTENANCE; starting tty1 login" >&2
            systemctl --no-block start getty@tty1.service || true
            ;;
    esac
}
trap maintenance_fallback EXIT
trap administrative_stop HUP INT TERM

command -v Xorg >/dev/null 2>&1 || {
    echo "nucore-xorg-only: Xorg is not installed" >&2
    exit 3
}
command -v xinit >/dev/null 2>&1 || {
    echo "nucore-xorg-only: xinit is not installed" >&2
    exit 3
}

cd "$ROOT_DIR"
echo "[nucore-xorg-only] starting minimal Xorg on tty1" >&2
xinit "$0" --client "$@" -- \
    :0 vt1 -keeptty -nolisten tcp -noreset -s 0 -dpms
