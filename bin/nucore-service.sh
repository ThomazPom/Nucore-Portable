#!/bin/bash
# Root-side service launcher. It attaches root Nucore to either the normal
# display-manager login or the dedicated standalone PAM/logind login.
set -e

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)

# Display-manager sessions may enter a compositor-owned overview during login.
# Wayland has no generic request for closing that UI, so probe the two public
# compositor interfaces we support instead of guessing the current desktop.
# This helper is invoked below as the unprivileged session user.
if [ "${1:-}" = --dismiss-overview ]; then
    command -v busctl >/dev/null 2>&1 || exit 0
    for _ in $(seq 1 50); do
        if busctl --user --quiet status org.gnome.Shell >/dev/null 2>&1; then
            busctl --user set-property org.gnome.Shell /org/gnome/Shell \
                org.gnome.Shell OverviewActive b false >/dev/null 2>&1 || true
        fi
        if busctl --user --quiet status org.kde.KWin >/dev/null 2>&1; then
            active_effects=$(busctl --user get-property org.kde.KWin /Effects \
                org.kde.kwin.Effects activeEffects 2>/dev/null || true)
            case "$active_effects" in
                *'"overview"'*)
                    busctl --user call org.kde.KWin /Effects \
                        org.kde.kwin.Effects toggleEffect s overview \
                        >/dev/null 2>&1 || true
                    ;;
            esac
        fi
        sleep 0.1
    done
    exit 0
fi

CONF=/etc/nucore-portable/session.conf
[ -r "$CONF" ] || { echo "nucore-service: missing $CONF" >&2; exit 3; }

SESSION_USER=$(sed -n 's/^SESSION_USER=//p' "$CONF" | head -n1)
OWNER_USER=$(sed -n 's/^OWNER_USER=//p' "$CONF" | head -n1)
[ -n "$OWNER_USER" ] || OWNER_USER=$SESSION_USER
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
nucore_pid=""

stop_nucore() {
    local i=0
    [ -n "$nucore_pid" ] || return 0
    kill -TERM -- "-$nucore_pid" 2>/dev/null || true
    while kill -0 "$nucore_pid" 2>/dev/null && [ "$i" -lt 50 ]; do
        i=$((i + 1)); sleep 0.1
    done
    if kill -0 "$nucore_pid" 2>/dev/null; then
        echo "nucore-service: Nucore ignored TERM; sending KILL" >&2
        kill -KILL -- "-$nucore_pid" 2>/dev/null || true
    fi
    wait "$nucore_pid" 2>/dev/null || true
    nucore_pid=""
}

end_standalone_session() {
    local i sessions
    [ "$BACKEND" != display-manager ] || return 0

    # First ask the login-owned backend to leave, then terminate the dedicated
    # login through logind. Stopping getty alone only kills its cgroup and does
    # not provide a synchronous guarantee that the logind session, user
    # manager, audio services and seat ownership have all disappeared.
    rm -f "$ENV_FILE" "$SESSION_DIR"/environment.* 2>/dev/null || true
    command -v loginctl >/dev/null 2>&1 || {
        echo "nucore-service: loginctl is required for a safe VT handoff" >&2
        return 1
    }
    loginctl terminate-user "$SESSION_USER" 2>/dev/null || true

    # Prevent a cabinet autologin from being recreated while logind tears the
    # old session down. This is the old cabinet getty, not the maintenance
    # getty which is installed only after the barrier below has passed.
    systemctl stop getty@tty1.service 2>/dev/null || true

    i=0
    while [ "$i" -lt 100 ]; do
        sessions=$(loginctl show-user "$SESSION_USER" -p Sessions --value 2>/dev/null || true)
        if [ -z "$sessions" ] &&
           ! systemctl is-active --quiet "user@${SESSION_UID}.service" 2>/dev/null &&
           ! systemctl is-active --quiet getty@tty1.service 2>/dev/null; then
            echo "nucore-service: cabinet login ended; VT handoff is safe" >&2
            return 0
        fi
        i=$((i + 1)); sleep 0.1
    done

    echo "nucore-service: cabinet login did not terminate; refusing VT handoff" >&2
    return 1
}

cleanup() {
    local result=0
    stop_nucore
    end_standalone_session || result=$?
    rm -f "$ROOT_RUNTIME_DIR/wayland-client" 2>/dev/null || true
    rmdir "$ROOT_RUNTIME_DIR" /run/nucore-portable 2>/dev/null || true
    if [ "$BACKEND" != display-manager ] && [ -d "$SESSION_DIR" ] &&
       [ "$(stat -c %u "$SESSION_DIR" 2>/dev/null)" = "$SESSION_UID" ]; then
        rmdir "$SESSION_DIR" 2>/dev/null || true
    fi
    return "$result"
}
start_maintenance() {
    [ "$BACKEND" != display-manager ] || return 0
    if [ "$MAINTENANCE" = display-manager ]; then
        systemctl --no-block start graphical.target display-manager.service 2>/dev/null || true
    else
        # Open an ordinary password-backed prompt for maintenance. This is also
        # the safe fallback when a selected display backend cannot initialize.
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
administrative_stop() { cleanup && exit 0 || exit 5; }
trap administrative_stop HUP INT TERM
unset DISPLAY XAUTHORITY WAYLAND_DISPLAY

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
    # agetty -> /bin/login -> PAM/logind owns the backend and publishes the
    # three dynamic display endpoints. Do not synthesize a user manager or
    # start a compositor from this privileged service.
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
        echo "nucore-service: cabinet display backend exited before becoming ready" >&2
        cleanup || exit 5
        start_maintenance
        exit 4
    }
    [ "$(stat -c %u "$SESSION_DIR" 2>/dev/null)" = "$SESSION_UID" ] || {
        echo "nucore-service: refusing cabinet session directory with wrong owner" >&2; exit 4;
    }
    [ "$(stat -c %u "$ENV_FILE")" = "$SESSION_UID" ] || {
        echo "nucore-service: refusing environment with wrong owner" >&2; exit 4;
    }
fi

import_display_environment() {
    endpoint_owner=$SESSION_UID
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
                           [ "$(stat -c %u "$value" 2>/dev/null)" = "$endpoint_owner" ]; then
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

SESSION_HOME=$(getent passwd "$OWNER_USER" | cut -d: -f6)
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

# A login overview can remain above a correctly fullscreen SDL window. Run the
# same capability-based adapters as Encore, only for a reused desktop session.
# setpriv drops to the real session identity without opening another PAM login.
if [ "$BACKEND" = display-manager ] && [ -S "$RUNTIME_DIR/bus" ] &&
   command -v setpriv >/dev/null 2>&1; then
    SESSION_GID=$(id -g "$SESSION_USER")
    setpriv --reuid="$SESSION_UID" --regid="$SESSION_GID" --init-groups \
        --no-new-privs --inh-caps=-all --ambient-caps=-all --bounding-set=-all \
        env HOME="$SESSION_HOME" USER="$SESSION_USER" LOGNAME="$SESSION_USER" \
            XDG_RUNTIME_DIR="$RUNTIME_DIR" \
            DBUS_SESSION_BUS_ADDRESS="unix:path=$RUNTIME_DIR/bus" \
            "$0" --dismiss-overview &
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
# start.sh's systemd-inhibit wrapper talks to logind on the system bus and is
# valid from this root service. Its fd lock follows Nucore's exact lifetime.
setsid "$ROOT_DIR/start.sh" --no-root "${LAUNCH_ARGS[@]}" "$@" &
nucore_pid=$!
wait "$nucore_pid" || status=$?
nucore_pid=""
cleanup || exit 5
trap - HUP INT TERM
[ "${NUCORE_TEST_NO_MAINTENANCE:-0}" = 1 ] || start_maintenance
exit "$status"
