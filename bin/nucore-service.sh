#!/bin/bash
# Root-side service launcher. Attach to a real PAM/logind user session without
# evaluating user-controlled shell syntax.
set -e

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
CONF=/etc/nucore-portable/session.conf
[ -r "$CONF" ] || { echo "nucore-service: missing $CONF" >&2; exit 3; }

SESSION_USER=$(sed -n 's/^SESSION_USER=//p' "$CONF" | head -n1)
BACKEND=$(sed -n 's/^BACKEND=//p' "$CONF" | head -n1)
MAINTENANCE=$(sed -n 's/^MAINTENANCE=//p' "$CONF" | head -n1)
SDL_DISPLAY=$(sed -n 's/^SDL_DISPLAY=//p' "$CONF" | head -n1)
[ -n "$SDL_DISPLAY" ] || SDL_DISPLAY=auto
SDL12_COMPAT=$(sed -n 's/^SDL12_COMPAT=//p' "$CONF" | head -n1)
[ -n "$SDL12_COMPAT" ] || SDL12_COMPAT=0
SESSION_UID=$(id -u "$SESSION_USER")
RUNTIME_DIR="/run/user/$SESSION_UID"
ROOT_RUNTIME_DIR=/run/nucore-portable/runtime
SESSION_DIR="$RUNTIME_DIR/nucore-portable"
ENV_FILE="$SESSION_DIR/display-environment"
ARGS_FILE=/etc/nucore-portable/launch.args
[ -r "$ARGS_FILE" ] || { echo "nucore-service: missing $ARGS_FILE" >&2; exit 3; }
mapfile -t LAUNCH_ARGS < "$ARGS_FILE"

cleanup() {
    [ -z "${backend_pid:-}" ] || kill "$backend_pid" 2>/dev/null || true
    [ -z "${backend_pid:-}" ] || wait "$backend_pid" 2>/dev/null || true
    rm -f "$ROOT_RUNTIME_DIR/wayland-client" 2>/dev/null || true
    rmdir "$ROOT_RUNTIME_DIR" /run/nucore-portable 2>/dev/null || true
    [ "$BACKEND" != display-manager ] || return 0
    [ -d "$SESSION_DIR" ] || return 0
    [ "$(stat -c %u "$SESSION_DIR" 2>/dev/null)" = "$SESSION_UID" ] || return 0
    rm -f "$ENV_FILE" "$SESSION_DIR"/environment.* 2>/dev/null || true
    rmdir "$SESSION_DIR" 2>/dev/null || true
}
start_maintenance() {
    [ "$BACKEND" != display-manager ] || return 0
    if [ "$MAINTENANCE" = display-manager ]; then
        systemctl stop getty@tty1.service 2>/dev/null || true
        systemctl --no-block start graphical.target display-manager.service 2>/dev/null || true
    else
        # Replace cabinet autologin for the remainder of this boot with an
        # ordinary password-backed prompt. This is also the safe fallback when
        # a selected display backend cannot initialize.
        install -d -m 0755 /run/nucore-portable
        install -m 0644 /dev/null /run/nucore-portable/maintenance-login
        install -d -m 0755 /run/systemd/system/getty@tty1.service.d
        cat > /run/systemd/system/getty@tty1.service.d/50-nucore-maintenance.conf <<'EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --noclear %I $TERM
StandardOutput=tty
StandardError=tty
EOF
        systemctl daemon-reload
        systemctl --no-block restart getty@tty1.service 2>/dev/null || true
    fi
}
administrative_stop() { cleanup; exit 0; }
trap administrative_stop HUP INT TERM
unset DISPLAY XAUTHORITY WAYLAND_DISPLAY
backend_pid=""

if [ "$BACKEND" = display-manager ]; then
    # A normal desktop session imports its live display addresses into the
    # user's systemd manager.  Query that authoritative runtime environment;
    # do not force an SDL driver or create a second graphical session.
    user_environment=""
    i=0
    while [ "$i" -lt 1800 ]; do
        if [ -S "$RUNTIME_DIR/bus" ]; then
            user_environment=$(runuser -u "$SESSION_USER" -- env \
                XDG_RUNTIME_DIR="$RUNTIME_DIR" \
                DBUS_SESSION_BUS_ADDRESS="unix:path=$RUNTIME_DIR/bus" \
                systemctl --user show-environment 2>/dev/null || true)
            if grep -qE '^(WAYLAND_DISPLAY|DISPLAY)=' <<< "$user_environment"; then
                break
            fi
        fi
        i=$((i + 1)); sleep 0.1
    done
    [ "$i" -lt 1800 ] || {
        echo "nucore-service: desktop display environment timeout" >&2; exit 4;
    }
else
    i=0
    getty_seen=0
    while [ "$i" -lt 1800 ] && [ ! -f "$ENV_FILE" ]; do
        if systemctl is-active --quiet getty@tty1.service; then
            getty_seen=1
        elif [ "$getty_seen" -eq 1 ]; then
            break
        fi
        i=$((i + 1)); sleep 0.1
    done
    [ -f "$ENV_FILE" ] || {
        echo "nucore-service: cabinet login/display backend exited before becoming ready" >&2
        start_maintenance
        exit 4
    }
    [ "$(stat -c %u "$RUNTIME_DIR" 2>/dev/null)" = "$SESSION_UID" ] || {
        echo "nucore-service: invalid user runtime directory" >&2; exit 4;
    }
    [ "$(stat -c %u "$SESSION_DIR" 2>/dev/null)" = "$SESSION_UID" ] || {
        echo "nucore-service: refusing session directory with wrong owner" >&2; exit 4;
    }
    [ "$(stat -c %u "$ENV_FILE")" = "$SESSION_UID" ] || {
        echo "nucore-service: refusing environment with wrong owner" >&2; exit 4;
    }
fi

# Xorg is deliberately owned by this already-privileged system service. The
# user login exists for PAM/logind/audio, not to elevate or own the display
# server. Root can acquire the cabinet VT directly on both real hardware and
# simple QEMU VGA devices.
if [ "$BACKEND" = xorg ]; then
    Xorg :0 vt1 -nolisten tcp -noreset -s 0 -dpms &
    backend_pid=$!
    i=0
    while [ "$i" -lt 100 ] && [ ! -S /tmp/.X11-unix/X0 ]; do
        kill -0 "$backend_pid" 2>/dev/null || {
            echo "nucore-service: root Xorg failed to initialize" >&2
            start_maintenance
            exit 4
        }
        i=$((i + 1)); sleep 0.1
    done
    [ -S /tmp/.X11-unix/X0 ] || {
        echo "nucore-service: root Xorg readiness timeout" >&2
        start_maintenance
        exit 4
    }
    export DISPLAY=:0
    export XAUTHORITY=/dev/null
fi

import_display_environment() {
    while IFS='=' read -r name value; do
        case "$name" in
            DISPLAY)
                case "$value" in :[0-9]*|unix/:[0-9]*) export DISPLAY="$value" ;; esac
                ;;
            WAYLAND_DISPLAY)
                case "$value" in */*|""|.|..) ;; *) export WAYLAND_DISPLAY="$value" ;; esac
                ;;
            XAUTHORITY)
                case "$value" in
                    /*)
                        if [ -f "$value" ] &&
                           [ "$(stat -c %u "$value" 2>/dev/null)" = "$SESSION_UID" ]; then
                            export XAUTHORITY="$value"
                        fi
                        ;;
                esac
                ;;
        esac
    done
}
if [ "$BACKEND" = display-manager ]; then
    import_display_environment <<< "$user_environment"
else
    import_display_environment < "$ENV_FILE"
fi

# Gamescope and similar standalone compositors commonly expose an Xwayland
# DISPLAY without an authority file.  Do not let Xlib fall back to an unrelated
# stale ~/.Xauthority entry for the same display number.  A backend-exported
# XAUTHORITY, when present and validated above, always wins.
case "$BACKEND" in
    gamescope|cage|weston)
        if [ -n "${DISPLAY:-}" ] && [ -z "${XAUTHORITY:-}" ]; then
            export XAUTHORITY=/dev/null
        fi
        ;;
esac

# Resolve and validate the socket while it still belongs to the real login
# session. It will be exposed inside root's own runtime directory below.
wayland_socket=""
if [ -n "${WAYLAND_DISPLAY:-}" ]; then
    case "$WAYLAND_DISPLAY" in
        /*) wayland_socket=$WAYLAND_DISPLAY ;;
        *)  wayland_socket="$RUNTIME_DIR/$WAYLAND_DISPLAY" ;;
    esac
    if [ -S "$wayland_socket" ] &&
       [ "$(stat -c %u "$wayland_socket" 2>/dev/null)" = "$SESSION_UID" ]; then
        :
    else
        wayland_socket=""
        unset WAYLAND_DISPLAY
    fi
fi

# Only SDL12-compat/SDL2 can consume a native Wayland display. Native SDL 1.2
# and an explicitly selected Xwayland path need neither the socket bridge nor
# Wayland-specific renderer settings.
if [ "$SDL12_COMPAT" != 1 ] || [ "$SDL_DISPLAY" = xwayland ]; then
    wayland_socket=""
    unset WAYLAND_DISPLAY
fi

SESSION_HOME=$(getent passwd "$SESSION_USER" | cut -d: -f6)
export HOME="$SESSION_HOME"
# Nucore is deliberately a root process.  A root process must not claim the
# login user's XDG runtime directory as its own. Give it a private directory;
# display and service addresses still come from the real login session.
install -d -m 0700 -o root -g root "$ROOT_RUNTIME_DIR"
export XDG_RUNTIME_DIR="$ROOT_RUNTIME_DIR"
if [ -n "$wayland_socket" ]; then
    rm -f "$ROOT_RUNTIME_DIR/wayland-client"
    ln -s "$wayland_socket" "$ROOT_RUNTIME_DIR/wayland-client"
    export WAYLAND_DISPLAY=wayland-client
    export SDL_VIDEO_WAYLAND_ALLOW_LIBDECOR=0
fi
if [ -S "$RUNTIME_DIR/bus" ]; then
    export DBUS_SESSION_BUS_ADDRESS="unix:path=$RUNTIME_DIR/bus"
else
    unset DBUS_SESSION_BUS_ADDRESS
fi
if [ -S "$RUNTIME_DIR/pulse/native" ]; then
    export PULSE_SERVER="unix:$RUNTIME_DIR/pulse/native"
else
    unset PULSE_SERVER
fi

# Native SDL 1.2 has no Wayland backend and, when Nucore runs as root on a
# cabinet VT, its automatic probe can select fbcon even though an X display is
# available.  That bypasses Gamescope/Xorg entirely and leaves the raw 640x480
# framebuffer in the top-left corner.  Graphical native-SDL sessions therefore
# select their only valid hosted backend explicitly.  Console and SDL2-compat
# sessions retain their normal discovery/installer-selected behaviour.
if [ "$SDL12_COMPAT" = 0 ] && [ "$BACKEND" != console ] &&
   [ -n "${DISPLAY:-}" ]; then
    export SDL_VIDEODRIVER=x11
fi

status=0
"$ROOT_DIR/start.sh" --no-root --no-inhibit "${LAUNCH_ARGS[@]}" "$@" || status=$?
cleanup
trap - HUP INT TERM
[ "${NUCORE_TEST_NO_MAINTENANCE:-0}" = 1 ] || start_maintenance
exit "$status"
