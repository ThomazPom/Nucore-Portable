#!/bin/bash
# nucore-as-root.sh — bridge a privileged systemd service into the user's
# already-running graphical session, AS A FIRST-CLASS MEMBER OF THAT
# SESSION (not as an alien root scope sitting beside it).
#
# Lifecycle:
#   1. Wait for an active local user session (Class=user, uid >= 1000).
#   2. Wait for that user's `graphical-session.target` (under their --user
#      systemd) to be fully active. This is the canonical "desktop is
#      done booting" signal — gnome-shell pulls it in only after mutter
#      is up, all autostart apps are launched, and the panel is ready.
#   3. Probe DISPLAY actually answers (XWayland on Wayland sessions can
#      lag a few seconds behind graphical-session.target).
#   4. Harvest the session's display + dbus + xdg env vars.
#   5. systemd-run the actual launcher into the user's own slice
#      (user-<uid>.slice / session-<id>.scope) so:
#        - logind sees nucore as part of the session (Esc/F1 exit ⇒
#          session keeps going, idle inhibitors track the right scope)
#        - gnome-shell does not treat it as an external root grab and
#          force-lock the screen
#        - cgroup accounting puts it under the user, not under the
#          system slice, so the compositor and nucore share the user's
#          memory + CPU policy as intended
#      The transient scope is still owned by uid=0 (we never drop the
#      caps the unit was started with — nucore needs CAP_SYS_RAWIO).
#
# Started by /etc/systemd/system/nucore.service (root, no User= line,
# WantedBy=graphical.target). All argv passes through to start.sh.

set -u

log() { printf '[nucore-as-root] %s\n' "$*" >&2; }

find_active_user_session() {
    # Output: "SESSION_ID UID DISPLAY TYPE"
    local sid
    while read -r sid _; do
        [ -z "$sid" ] && continue
        unset User Display Type Active Remote Class
        eval "$(loginctl show-session "$sid" \
                  -p User -p Display -p Type -p Active -p Remote -p Class \
                  2>/dev/null \
                | sed 's/^/local /')" || continue
        [ "${Active:-}" = "yes" ]   || continue
        [ "${Remote:-}" = "no" ]    || continue
        [ "${Class:-}"  = "user" ]  || continue
        [ "${User:-0}" -ge 1000 ]   || continue
        case "${Type:-}" in
            x11|wayland|mir) ;;
            *) continue ;;
        esac
        printf '%s %s %s %s\n' "$sid" "$User" "${Display:-}" "$Type"
        return 0
    done < <(loginctl list-sessions --no-legend 2>/dev/null)
    return 1
}

# ── 1. wait for an active local user session (up to 30 min) ─────────────────
SESSION_INFO=""
for _ in $(seq 1 3600); do
    if SESSION_INFO=$(find_active_user_session); then
        break
    fi
    sleep 0.5
done

if [ -z "$SESSION_INFO" ]; then
    log "no active local user session appeared within 30 min — giving up"
    exit 1
fi

read -r SESS_ID SESS_UID SESS_DISPLAY SESS_TYPE <<<"$SESSION_INFO"
SESS_USER=$(getent passwd "$SESS_UID" | cut -d: -f1)
SESS_HOME=$(getent passwd "$SESS_UID" | cut -d: -f6)
RUNDIR="/run/user/$SESS_UID"

log "session ready: id=$SESS_ID user=$SESS_USER uid=$SESS_UID display=${SESS_DISPLAY:-?} type=$SESS_TYPE"

# ── 2. wait for the user's graphical-session.target to be ACTIVE ────────────
# This is the single most reliable "GNOME is fully up" signal — gnome-shell
# itself pulls it in only after the panel is showing. Without this gate the
# wrapper attaches mid-boot, when mutter is partially initialised, and the
# resulting SDL fullscreen grab racing the compositor's first frames is
# what destroys the session.
log "waiting for $SESS_USER's graphical-session.target..."
GST_OK=0
for _ in $(seq 1 240); do  # 240 * 0.5s = 2 min
    state=$(systemctl --user --machine="$SESS_USER@" \
                is-active graphical-session.target 2>/dev/null || true)
    if [ "$state" = "active" ]; then
        GST_OK=1
        break
    fi
    sleep 0.5
done
if [ "$GST_OK" = 1 ]; then
    log "graphical-session.target is active"
else
    log "warning: graphical-session.target never reported active (continuing anyway)"
fi

# ── 3. harvest the session's environment ────────────────────────────────────
# `systemctl --user show-environment` is the canonical place where GNOME
# (and KDE, sway, etc.) push DISPLAY / WAYLAND_DISPLAY / XAUTHORITY /
# DBUS_SESSION_BUS_ADDRESS / XDG_* during session startup. Inheriting from
# there is much more reliable than guessing file paths under /run.
declare -a SESS_ENV=()
while IFS= read -r line; do
    case "$line" in
        DISPLAY=*|WAYLAND_DISPLAY=*|XAUTHORITY=*|\
        DBUS_SESSION_BUS_ADDRESS=*|XDG_SESSION_ID=*|XDG_SESSION_TYPE=*|\
        XDG_SESSION_DESKTOP=*|XDG_CURRENT_DESKTOP=*|XDG_RUNTIME_DIR=*|\
        GDMSESSION=*|GNOME_SHELL_SESSION_MODE=*|GNOME_SETUP_DISPLAY=*|\
        LANG=*|LC_*)
            SESS_ENV+=("$line")
            ;;
    esac
done < <(systemctl --user --machine="$SESS_USER@" show-environment 2>/dev/null)

# Helper: read a specific KEY=VAL out of SESS_ENV.
sess_env_get() {
    local key="$1"
    local kv
    for kv in "${SESS_ENV[@]}"; do
        case "$kv" in "$key="*) echo "${kv#*=}"; return 0 ;; esac
    done
    return 1
}

# Always-on essentials. Fallback to logind / sensible defaults if the
# user's --user systemd hasn't pushed them yet.
WANT_DISPLAY=$(sess_env_get DISPLAY || true)
[ -z "$WANT_DISPLAY" ] && WANT_DISPLAY="${SESS_DISPLAY:-:0}"
SESS_ENV+=("DISPLAY=$WANT_DISPLAY")

WANT_RUNDIR=$(sess_env_get XDG_RUNTIME_DIR || true)
[ -z "$WANT_RUNDIR" ] && SESS_ENV+=("XDG_RUNTIME_DIR=$RUNDIR")

# XAUTHORITY: try the value the session published; else probe sane locations.
WANT_XAUTH=$(sess_env_get XAUTHORITY || true)
if [ -z "$WANT_XAUTH" ] || [ ! -r "$WANT_XAUTH" ]; then
    for cand in \
        "$RUNDIR"/.mutter-Xwaylandauth.* \
        "$SESS_HOME/.Xauthority" \
        "$RUNDIR/gdm/Xauthority"
    do
        [ -r "$cand" ] || continue
        WANT_XAUTH="$cand"
        SESS_ENV+=("XAUTHORITY=$cand")
        break
    done
fi
[ -n "$WANT_XAUTH" ] && log "XAUTHORITY=$WANT_XAUTH"
log "DISPLAY=$WANT_DISPLAY"

# ── 4. probe DISPLAY actually answers ───────────────────────────────────────
# graphical-session.target can flip to active a beat before XWayland is
# answering on Wayland sessions. Probe for up to 30s, then give the
# compositor a final 2-second settle so SDL's fullscreen grab doesn't
# race mutter's first frames.
probe_display() {
    if command -v xdpyinfo >/dev/null 2>&1; then
        XAUTHORITY="$WANT_XAUTH" DISPLAY="$WANT_DISPLAY" \
            xdpyinfo >/dev/null 2>&1 && return 0
    elif command -v xset >/dev/null 2>&1; then
        XAUTHORITY="$WANT_XAUTH" DISPLAY="$WANT_DISPLAY" \
            xset q >/dev/null 2>&1 && return 0
    else
        [ -S "/tmp/.X11-unix/X${WANT_DISPLAY#:}" ] && return 0
    fi
    return 1
}
for _ in $(seq 1 60); do
    probe_display && break
    sleep 0.5
done
probe_display || log "warning: $WANT_DISPLAY did not answer within 30s"
sleep 2

# Belt-and-braces: explicitly let root talk to the X server (no-op if
# the cookie is already valid; harmless on Wayland).
if command -v xhost >/dev/null 2>&1; then
    su - "$SESS_USER" -c \
        "DISPLAY=$WANT_DISPLAY XAUTHORITY=${WANT_XAUTH:-} xhost +SI:localuser:root" \
        >/dev/null 2>&1 || true
fi

# ── 5. systemd-run into the user's slice/scope ──────────────────────────────
# This is what makes nucore "bound to the user logind session" instead of
# being an alien root process living in the system slice:
#   --slice=user-<uid>.slice  -> cgroup parent is the user's slice
#   --scope                   -> creates a transient scope as a peer of
#                                gnome-shell's own scopes (not a service)
#   --uid=0 / --gid=0         -> stays as root (we keep CAP_SYS_RAWIO)
#   PAMName= NOT set          -> we DON'T re-PAM; we are already a
#                                privileged child of the system unit, we
#                                just want the cgroup placement.
#
# When nucore exits (Esc / F1 / coin-door menu), systemd-run returns and
# the wrapper exits, the system unit exits, and we are cleanly back at
# the GNOME desktop with no lingering scope.
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$SCRIPT_DIR"

# Build --setenv flags from the harvested session env.
SETENV_ARGS=()
for kv in "${SESS_ENV[@]}"; do
    SETENV_ARGS+=(--setenv="$kv")
done

# Background helper: a couple of seconds after we exec systemd-run, dismiss
# any "show the desktop overview on login" state the desktop may be in.
# - GNOME 40+ drops a fresh session straight into the Activities overview.
#   Toggle it off via org.gnome.Shell OverviewActive=false (no packages).
# - KDE Plasma 6 has an "Overview" effect that can be open after login if
#   the user enabled "Open overview on login"; close it via the
#   org.kde.kglobalaccel "Toggle Overview" shortcut over D-Bus. (No-op on
#   Plasma 5 / when not active.)
# - XFCE / MATE / LXQt / Cinnamon: no equivalent, helper is a no-op.
# All calls are best-effort and silent.
SESS_DBUS=$(sess_env_get DBUS_SESSION_BUS_ADDRESS || true)
SESS_DESKTOP=$(sess_env_get XDG_CURRENT_DESKTOP || true)
if [ -n "$SESS_DBUS" ] && command -v gdbus >/dev/null 2>&1; then
    (
        sleep 3
        for _ in 1 2 3 4 5; do
            DONE=0
            case "$SESS_DESKTOP" in
                *GNOME*|*Unity*|"")
                    su - "$SESS_USER" -c \
                        "DBUS_SESSION_BUS_ADDRESS='$SESS_DBUS' \
                         gdbus call --session \
                            --dest org.gnome.Shell \
                            --object-path /org/gnome/Shell \
                            --method org.freedesktop.DBus.Properties.Set \
                            'org.gnome.Shell' 'OverviewActive' '<false>'" \
                        >/dev/null 2>&1 && DONE=1
                    ;;
            esac
            case "$SESS_DESKTOP" in
                *KDE*|*Plasma*)
                    # KWin's "Overview" effect — toggle via its own D-Bus.
                    # Calling deactivate() is a no-op when not active.
                    su - "$SESS_USER" -c \
                        "DBUS_SESSION_BUS_ADDRESS='$SESS_DBUS' \
                         gdbus call --session \
                            --dest org.kde.KWin \
                            --object-path /org/kde/KWin/Effect/Overview1 \
                            --method org.kde.KWin.Effect.Overview1.deactivate" \
                        >/dev/null 2>&1 && DONE=1
                    ;;
            esac
            [ "$DONE" = 1 ] && break
            sleep 1
        done
    ) &
fi

# start.sh is invoked with --no-inhibit because the desktop session
# already has its own inhibitors, and with EUID=0 it skips its own
# escalation chain entirely.
log "exec'ing nucore into user-${SESS_UID}.slice"
exec systemd-run \
    --quiet \
    --wait \
    --pipe \
    --collect \
    --slice="user-${SESS_UID}.slice" \
    --uid=0 --gid=0 \
    --unit="nucore-session-${SESS_UID}" \
    --description="Pinball 2000 (in $SESS_USER's session)" \
    "${SETENV_ARGS[@]}" \
    -- "$SCRIPT_DIR/start.sh" --no-inhibit "$@"
