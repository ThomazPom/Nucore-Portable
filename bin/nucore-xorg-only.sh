#!/bin/bash
# Dedicated cabinet session: one minimal Xorg server, one Nucore client, no
# display manager or desktop environment. Called by nucore.service on tty1.

set -e

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)

if [ "${1:-}" = --client ]; then
    shift
    # xinit supplies DISPLAY and XAUTHORITY. Force both SDL implementations
    # through X11 so native SDL and sdl12-compat share the proven path.
    exec env SDL_VIDEODRIVER=x11 \
        "$ROOT_DIR/start.sh" --no-root --no-inhibit "$@"
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
    echo "[nucore-xorg-only] Nucore/Xorg exited; opening maintenance environment" >&2
    if systemctl cat display-manager.service >/dev/null 2>&1; then
        systemctl --no-block start graphical.target display-manager.service || true
    else
        systemctl --no-block start getty@tty1.service || true
    fi
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
