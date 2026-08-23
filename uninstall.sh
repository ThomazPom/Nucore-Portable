#!/bin/bash
# uninstall.sh — reverse install.sh.
#
# Symmetric with the session-oriented installer: remove its service/session
# files and restore the boot target and tty state recorded before installation.

set -e

if [ "$EUID" -ne 0 ]; then
    for esc in run0 pkexec sudo; do
        # systemd may provide run0 even when the polkit authentication agent
        # needed by an interactive non-root caller is absent (notably on a
        # stripped Debian installation). Do not select that unusable path and
        # hide a working pkexec or sudo fallback.
        if command -v "$esc" >/dev/null 2>&1 &&
           { [ "$esc" != run0 ] || command -v pkttyagent >/dev/null 2>&1; }; then
            echo "[uninstall.sh] re-launching under $esc to gain root..."
            case "$esc" in
                run0)   exec run0 --description="nucore-portable uninstaller" -- "$0" "$@" ;;
                pkexec) exec pkexec "$0" "$@" ;;
                sudo)   exec sudo "$0" "$@" ;;
            esac
        fi
    done
    echo "uninstall.sh: must be run as root, and no escalator available." >&2
    exit 1
fi

STATE_DIR=/var/lib/nucore-portable
GRUB_DROPIN=/etc/default/grub.d/99-nucore-portable.cfg
GRUB_QUIET_SCRIPT=/etc/grub.d/01_nucore_portable_quiet
BACKPORTS_APT_SOURCE=/etc/apt/sources.list.d/nucore-portable-backports.sources
LEGACY_GAMESCOPE_APT_SOURCE=/etc/apt/sources.list.d/nucore-portable-gamescope.sources
CABINET_LOCK=/var/lib/pinball2000-cabinet.lock
LOCK_OWNER=$(sed -n '1p' "$CABINET_LOCK" 2>/dev/null || true)
if [ "$LOCK_OWNER" != nucore ]; then
    echo "uninstall.sh: cabinet lock belongs to '${LOCK_OWNER:-nobody}', not nucore; nothing changed." >&2
    exit 2
fi
echo "[+] stopping & disabling nucore.service"
INSTALL_MODE=""
[ -f "$STATE_DIR/install-mode" ] && INSTALL_MODE=$(sed -n '1p' "$STATE_DIR/install-mode")
CABINET_USER=""
[ -f "$STATE_DIR/cabinet-user-created" ] && CABINET_USER=$(sed -n '1p' "$STATE_DIR/cabinet-user-created")
systemctl stop nucore.service    2>/dev/null || true
systemctl disable nucore.service 2>/dev/null || true
# Explicitly close the project account through logind before releasing tty1.
# The service normally completed this barrier already; repeat it idempotently
# so uninstall also handles a failed or previously killed service safely. Do
# not stop getty@tty1 here: after a normal game exit it belongs to the human
# maintenance login which may be running this very uninstaller.
if [ "$CABINET_USER" = nucore-cabinet ] && getent passwd "$CABINET_USER" >/dev/null; then
    CABINET_UID=$(id -u "$CABINET_USER")
    loginctl terminate-user "$CABINET_USER" 2>/dev/null || true
    SESSION_END_WAIT=0
    while [ "$SESSION_END_WAIT" -lt 100 ]; do
        CABINET_SESSIONS=$(loginctl show-user "$CABINET_USER" -p Sessions --value 2>/dev/null || true)
        if [ -z "$CABINET_SESSIONS" ] &&
           ! systemctl is-active --quiet "user@${CABINET_UID}.service" 2>/dev/null; then
            break
        fi
        SESSION_END_WAIT=$((SESSION_END_WAIT + 1))
        sleep 0.1
    done
    if [ "$SESSION_END_WAIT" -ge 100 ]; then
        echo "uninstall.sh: dedicated cabinet login did not terminate; refusing removal" >&2
        exit 3
    fi
fi
rm -f /etc/systemd/system/nucore.service
rm -f /etc/polkit-1/rules.d/49-nucore.rules
# Remove files from the short-lived global-login implementation too, so this
# uninstaller can safely upgrade or remove that committed fallback state.
rm -f /etc/profile.d/nucore-cabinet.sh
rm -f /etc/xdg/autostart/nucore-cabinet.desktop
rm -f /usr/share/xsessions/nucore.desktop
rm -f /usr/share/wayland-sessions/nucore.desktop
rm -f /etc/systemd/system/getty@tty1.service.d/49-nucore-portable.conf
rm -f /run/systemd/system/getty@tty1.service.d/50-nucore-maintenance.conf
rm -f /run/nucore-portable/maintenance-login
rmdir /etc/systemd/system/getty@tty1.service.d 2>/dev/null || true
rmdir /run/systemd/system/getty@tty1.service.d 2>/dev/null || true
rmdir /run/nucore-portable 2>/dev/null || true
rm -f /etc/nucore-portable/session.conf
rm -f /etc/nucore-portable/launch.args
rmdir /etc/nucore-portable 2>/dev/null || true
systemctl daemon-reload

if [ "$CABINET_USER" = nucore-cabinet ]; then
    if getent passwd "$CABINET_USER" >/dev/null; then
        echo "[+] removing dedicated cabinet account $CABINET_USER"
        CABINET_UID=$(id -u "$CABINET_USER")
        userdel -r "$CABINET_USER" 2>/dev/null || {
            echo "uninstall.sh: could not remove $CABINET_USER" >&2
            exit 3
        }
    fi
    rm -f /usr/local/libexec/nucore-cabinet-login /usr/local/libexec/nucore-wm
    rmdir /usr/local/libexec 2>/dev/null || true
fi

if [ -s "$STATE_DIR/original-login-shell" ] &&
   [ -s "$STATE_DIR/login-shell-user" ] &&
   [ -s "$STATE_DIR/installed-login-shell" ]; then
    LOGIN_SHELL_USER=$(sed -n '1p' "$STATE_DIR/login-shell-user")
    ORIGINAL_LOGIN_SHELL=$(sed -n '1p' "$STATE_DIR/original-login-shell")
    INSTALLED_LOGIN_SHELL=$(sed -n '1p' "$STATE_DIR/installed-login-shell")
    CURRENT_LOGIN_SHELL=$(getent passwd "$LOGIN_SHELL_USER" 2>/dev/null | cut -d: -f7)
    if [ "$CURRENT_LOGIN_SHELL" = "$INSTALLED_LOGIN_SHELL" ]; then
        echo "[+] restoring $LOGIN_SHELL_USER login shell"
        usermod -s "$ORIGINAL_LOGIN_SHELL" "$LOGIN_SHELL_USER"
    else
        echo "[!] $LOGIN_SHELL_USER login shell changed since installation; leaving it untouched" >&2
    fi
fi

for project_source in "$BACKPORTS_APT_SOURCE" "$LEGACY_GAMESCOPE_APT_SOURCE"; do
    [ -f "$project_source" ] || continue
    if grep -q '^# nucore-portable managed Debian backports$' "$project_source" ||
       grep -q '^# nucore-portable managed Gamescope backports$' "$project_source"; then
        echo "[+] removing project-added Debian backports source"
        rm -f "$project_source"
    fi
done

if [ -s "$STATE_DIR/hushlogin-created" ]; then
    HUSHLOGIN=$(sed -n '1p' "$STATE_DIR/hushlogin-created")
    HUSHLOGIN_ID=$(sed -n '2p' "$STATE_DIR/hushlogin-created")
    case "$HUSHLOGIN" in
        /*/.hushlogin)
            if [ -f "$HUSHLOGIN" ] && [ ! -s "$HUSHLOGIN" ] &&
               [ "$(stat -c '%d:%i' "$HUSHLOGIN" 2>/dev/null)" = "$HUSHLOGIN_ID" ]; then
                rm -f -- "$HUSHLOGIN"
            else
                echo "    leaving changed hushlogin in place: $HUSHLOGIN" >&2
            fi
            ;;
    esac
fi

GRUB_CHANGED=0
if [ -f "$GRUB_QUIET_SCRIPT" ] &&
   grep -q '^# nucore-portable managed silent GRUB handoff$' "$GRUB_QUIET_SCRIPT"; then
    rm -f "$GRUB_QUIET_SCRIPT"
    GRUB_CHANGED=1
fi
if [ -f "$GRUB_DROPIN" ] &&
   grep -q '^# nucore-portable managed boot presentation$' "$GRUB_DROPIN"; then
    rm -f "$GRUB_DROPIN"
    GRUB_CHANGED=1
fi
if [ "$GRUB_CHANGED" -eq 1 ]; then
    echo "[+] restoring GRUB boot presentation"
    if command -v update-grub >/dev/null 2>&1; then
        update-grub
    else
        echo "    update-grub unavailable; regenerate GRUB configuration manually" >&2
    fi
fi

if [ "$INSTALL_MODE" = xorg-only ] || [ "$INSTALL_MODE" = xorg ] ||
   [ "$INSTALL_MODE" = console ] || [ "$INSTALL_MODE" = kmsdrm ] || [ "$INSTALL_MODE" = cage ] ||
   [ "$INSTALL_MODE" = weston ] || [ "$INSTALL_MODE" = gamescope ]; then
    echo "[+] restoring boot target and tty1 getty"
    # Also repairs installations made by the older console experiment, which
    # masked rather than disabled getty@tty1.
    systemctl unmask getty@tty1.service 2>/dev/null || true
    GETTY_STATE=""
    [ -f "$STATE_DIR/getty-tty1-was-enabled" ] &&
        GETTY_STATE=$(sed -n '1p' "$STATE_DIR/getty-tty1-was-enabled")
    case "$GETTY_STATE" in
      enabled|enabled-runtime|alias|static)
        systemctl enable getty@tty1.service 2>/dev/null || true
        # `enable` handles later boots. Start it immediately only when no
        # display manager owns the local screen; otherwise a freshly started
        # tty1 can steal the visible VT from an intact desktop session.
        if ! systemctl is-active --quiet display-manager.service 2>/dev/null; then
            systemctl start getty@tty1.service 2>/dev/null || true
        fi ;;
      masked|masked-runtime)
        systemctl disable getty@tty1.service 2>/dev/null || true
        systemctl mask getty@tty1.service 2>/dev/null || true ;;
      *)
        systemctl disable getty@tty1.service 2>/dev/null || true ;;
    esac
    if [ -s "$STATE_DIR/previous-default-target" ]; then
        PREVIOUS_TARGET=$(sed -n '1p' "$STATE_DIR/previous-default-target")
        case "$PREVIOUS_TARGET" in
            *.target) systemctl set-default "$PREVIOUS_TARGET" ;;
            *) echo "    invalid saved target '$PREVIOUS_TARGET'; leaving current target unchanged" >&2 ;;
        esac
    fi
fi

if [ "$INSTALL_MODE" = display-manager ] &&
   [ -s "$STATE_DIR/previous-default-target" ]; then
    PREVIOUS_TARGET=$(sed -n '1p' "$STATE_DIR/previous-default-target")
    case "$PREVIOUS_TARGET" in
        *.target) systemctl set-default "$PREVIOUS_TARGET" ;;
        *) echo "    invalid saved target '$PREVIOUS_TARGET'; leaving current target unchanged" >&2 ;;
    esac
fi

echo "[+] removing display-manager autologin (GDM / SDDM / LightDM)"
strip_block() {
    local conf="$1" tmp
    [ -f "$conf" ] || return 0
    grep -q '^# >>> nucore-portable autologin >>>$' "$conf" || return 0
    tmp=$(mktemp)
    awk '
        /^# >>> nucore-portable autologin >>>$/ { skip=1; next }
        /^# <<< nucore-portable autologin <<<$/ { skip=0; next }
        !skip { print }
    ' "$conf" > "$tmp"
    install -m 0644 "$tmp" "$conf"
    rm -f "$tmp"
    echo "    cleaned $conf"
}
# GDM (Debian/Ubuntu + Fedora paths) — block-strip in-place.
for conf in /etc/gdm3/daemon.conf /etc/gdm/custom.conf; do
    strip_block "$conf"
done
# SDDM + LightDM — we wrote standalone drop-in files, just delete them.
rm -f /etc/sddm.conf.d/49-nucore.conf
rm -f /etc/lightdm/lightdm.conf.d/49-nucore.conf
# rmdir if we created the dir and it's now empty (harmless if it isn't).
rmdir /etc/sddm.conf.d 2>/dev/null || true
rmdir /etc/lightdm/lightdm.conf.d 2>/dev/null || true

rm -f "$STATE_DIR/install-mode" \
      "$STATE_DIR/previous-default-target" \
      "$STATE_DIR/getty-tty1-was-enabled" \
      "$STATE_DIR/original-login-shell" \
      "$STATE_DIR/login-shell-user" \
      "$STATE_DIR/installed-login-shell" \
      "$STATE_DIR/gdm-session-state" \
      "$STATE_DIR/gdm-xsession-state" \
      "$STATE_DIR/install-user" \
      "$STATE_DIR/cabinet-user-created" \
      "$STATE_DIR/hushlogin-created"
rmdir "$STATE_DIR" 2>/dev/null || true
if [ "$(sed -n '1p' "$CABINET_LOCK" 2>/dev/null || true)" = nucore ]; then
    rm -f "$CABINET_LOCK"
fi

echo "=== uninstall complete ==="
echo "All project-owned system changes made by install.sh were removed."
