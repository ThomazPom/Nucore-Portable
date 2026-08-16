#!/bin/bash
# Cabinet backend host and display-ready rendezvous. Standalone execution is
# the login shell of the locked cabinet account, after /bin/login and PAM/logind
# have established its real user/seat session.
set -e

# Debian installs Gamescope and its private gamescopereaper helper in
# /usr/games. Login shells normally add it, but standalone cabinet backends do
# not create a login shell. Add it once for both installed and manual runs.
case ":$PATH:" in
    *:/usr/games:*) ;;
    *) PATH=$PATH:/usr/games; export PATH ;;
esac

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
CONF=/etc/nucore-portable/session.conf
SELF="$SCRIPT_DIR/$(basename -- "$0")"
WM_BINARY="$SCRIPT_DIR/nucore-wm"

client_main() {
    shift
    nested_host=0
    if [ "${1:-}" = --nested-host ]; then
        nested_host=1
        shift
    fi
    runtime_dir=${XDG_RUNTIME_DIR:?XDG_RUNTIME_DIR is required}
    session_dir="$runtime_dir/nucore-portable"
    env_file="$session_dir/display-environment"
    tmp=""
    wm_pid=""
    root_x11_granted=0

    client_cleanup() {
        if [ "$root_x11_granted" -eq 1 ]; then
            xhost -SI:localuser:root >/dev/null 2>&1 || true
        fi
        [ -n "$wm_pid" ] && kill "$wm_pid" 2>/dev/null || true
        [ -n "$wm_pid" ] && wait "$wm_pid" 2>/dev/null || true
        [ -n "$tmp" ] && rm -f "$tmp"
        rm -f "$env_file"
        rmdir "$session_dir" 2>/dev/null || true
    }
    trap client_cleanup EXIT
    trap 'exit 0' INT TERM

    umask 077
    mkdir -p "$session_dir"
    rm -f "$env_file" "$session_dir"/environment.*

    # pam_systemd starts the user manager. Wait for its ordinary default target
    # without naming or manually starting a distribution audio service.
    if command -v systemctl >/dev/null 2>&1 &&
       systemctl --user show-environment >/dev/null 2>&1; then
        i=0
        while [ "$i" -lt 300 ] &&
              ! systemctl --user is-active --quiet default.target 2>/dev/null; do
            i=$((i + 1)); sleep 0.1
        done
    fi

    tmp=$(mktemp "$session_dir/environment.XXXXXX")
    # A standalone Wayland compositor may also expose Xwayland. Publish only
    # the endpoint selected by the installer. Old SDL12-compat configurations
    # used native Wayland, so a missing SDL_DISPLAY keeps that behaviour.
    sdl_display=$(sed -n 's/^SDL_DISPLAY=//p' "$CONF" 2>/dev/null | head -n1)
    [ -n "$sdl_display" ] || sdl_display=wayland
    # A compositor nested in the current desktop creates its own Xwayland
    # DISPLAY but may leave the parent desktop's XAUTHORITY in the environment.
    # That cookie belongs to the outer X server and must not be reused for the
    # nested one. The narrowly scoped xhost grant below handles root access.
    [ "$nested_host" -eq 0 ] || unset XAUTHORITY
    if [ -n "${WAYLAND_DISPLAY:-}" ] &&
       grep -q '^SDL12_COMPAT=1$' "$CONF" 2>/dev/null &&
       [ "$sdl_display" = wayland ]; then
        unset DISPLAY XAUTHORITY
    fi

    # A rootless Xwayland normally accepts only clients running as the login
    # user. Nucore intentionally remains a root system service, so grant that
    # one local identity access for this cabinet session and revoke it when the
    # backend closes. Never disable X access control globally.
    if [ -n "${DISPLAY:-}" ] && [ -z "${XAUTHORITY:-}" ]; then
        command -v xhost >/dev/null 2>&1 || {
            echo "nucore-session: xhost is required for root Nucore on Xwayland" >&2
            exit 4
        }
        xhost +SI:localuser:root >/dev/null
        root_x11_granted=1
    fi
    # These are the only session values that the selected display server
    # creates dynamically; runtime and D-Bus paths are derived by the service.
    for name in DISPLAY XAUTHORITY WAYLAND_DISPLAY; do
        value=${!name:-}
        [ -n "$value" ] || continue
        case "$value" in *$'\n'*|*$'\r'*) continue ;; esac
        printf '%s=%s\n' "$name" "$value" >> "$tmp"
    done

    # SDL2 fullscreen on bare Xorg needs the small EWMH helper.
    if [ "${1:-}" = --xorg ] &&
       grep -q '^SDL12_COMPAT=1$' "$CONF" 2>/dev/null; then
        "$WM_BINARY" &
        wm_pid=$!
        i=0
        while [ "$i" -lt 50 ]; do
            "$WM_BINARY" --ready 2>/dev/null && break
            kill -0 "$wm_pid" 2>/dev/null || {
                echo "nucore-session: nucore-wm failed" >&2; exit 4;
            }
            i=$((i + 1)); sleep 0.02
        done
        [ "$i" -lt 50 ] || {
            echo "nucore-session: nucore-wm readiness timeout" >&2; exit 4;
        }
    fi

    mv -f "$tmp" "$env_file"
    tmp=""
    while [ -e "$env_file" ]; do sleep 1; done
}

if [ "${1:-}" = --client ]; then
    client_main "$@"
    exit 0
fi

[ -r "$CONF" ] || { echo "nucore-session: missing $CONF" >&2; exit 3; }
BACKEND=$(sed -n 's/^BACKEND=//p' "$CONF" | head -n1)
DESKTOP_HOST=0
if [ "${1:-}" = --desktop-host ]; then
    DESKTOP_HOST=1
    shift
fi

client_args=(--client)
[ "$DESKTOP_HOST" -eq 0 ] || client_args+=(--nested-host)

if [ "$BACKEND" != display-manager ] && [ "$DESKTOP_HOST" -eq 0 ]; then
    unset DISPLAY XAUTHORITY WAYLAND_DISPLAY
fi

case "$BACKEND" in
    xorg)
        # xinit keeps Xorg and its client in this login's cgroup, so ending the
        # login releases the VT before maintenance starts.
        exec xinit "$SELF" "${client_args[@]}" -- \
            /usr/bin/Xorg :0 vt1 -nolisten tcp -noreset -s 0 -dpms
        ;;
    cage)
        exec cage -- "$SELF" "${client_args[@]}"
        ;;
    gamescope)
        # Keep the game at its native 640x480, but let Gamescope discover the
        # physical output and fit/centre it there. Never pass -W/-H, which
        # would assume a host resolution.
        gamescope_args=(-w 640 -h 480 -S fit --force-windows-fullscreen)
        if grep -q '^SDL12_COMPAT=1$' "$CONF" 2>/dev/null &&
           ! grep -q '^SDL_DISPLAY=xwayland$' "$CONF" 2>/dev/null; then
            gamescope_args+=(--expose-wayland)
        fi
        if command -v gamescope >/dev/null 2>&1; then
            gamescope_binary=$(command -v gamescope)
        else
            gamescope_binary=/usr/games/gamescope
        fi
        [ "$DESKTOP_HOST" -eq 0 ] || gamescope_args=(--backend wayland "${gamescope_args[@]}")
        exec systemd-cat --identifier=nucore-gamescope -- \
            "$gamescope_binary" "${gamescope_args[@]}" -- "$SELF" "${client_args[@]}"
        ;;
    weston)
        # Weston must spawn the client itself so its exported Wayland/Xwayland
        # addresses reach the client process (a child cannot alter this shell).
        weston_args=(--shell=kiosk-shell.so --xwayland --idle-time=0)
        [ "$DESKTOP_HOST" -eq 0 ] || weston_args+=(--backend=wayland)
        exec weston "${weston_args[@]}" -- "$SELF" "${client_args[@]}"
        ;;
    console|kmsdrm)
        exec "$SELF" "${client_args[@]}"
        ;;
    *)
        echo "nucore-session: invalid backend '$BACKEND'" >&2
        exit 3
        ;;
esac
