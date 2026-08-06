#!/bin/bash
# uninstall.sh — reverse install.sh.
#
# Symmetric with install.sh: remove its service and restore the exact boot
# target/getty state used before xorg-only or console installation. Desktop
# autologin changes are removed separately below.
#
# bin/nucore-as-root.sh stays in the bundle (it ships with the source
# tree, not installed under /).

set -e

if [ "$EUID" -ne 0 ]; then
    for esc in run0 sudo pkexec; do
        if command -v "$esc" >/dev/null 2>&1; then
            echo "[uninstall.sh] re-launching under $esc to gain root..."
            case "$esc" in
                run0)   exec run0 --description="nucore-portable uninstaller" -- "$0" "$@" ;;
                sudo)   exec sudo "$0" "$@" ;;
                pkexec) exec pkexec "$0" "$@" ;;
            esac
        fi
    done
    echo "uninstall.sh: must be run as root, and no escalator available." >&2
    exit 1
fi

echo "[+] stopping & disabling nucore.service"
STATE_DIR=/var/lib/nucore-portable
INSTALL_MODE=""
[ -f "$STATE_DIR/install-mode" ] && INSTALL_MODE=$(sed -n '1p' "$STATE_DIR/install-mode")
systemctl stop nucore.service    2>/dev/null || true
systemctl disable nucore.service 2>/dev/null || true
rm -f /etc/systemd/system/nucore.service
rm -f /etc/polkit-1/rules.d/49-nucore.rules
systemctl daemon-reload

if [ "$INSTALL_MODE" = xorg-only ] || [ "$INSTALL_MODE" = console ]; then
    echo "[+] restoring boot target and tty1 getty"
    # Also repairs installations made by the older console experiment, which
    # masked rather than disabled getty@tty1.
    systemctl unmask getty@tty1.service 2>/dev/null || true
    if [ -f "$STATE_DIR/getty-tty1-was-enabled" ] &&
       grep -Eq '^(enabled|enabled-runtime|alias|static)$' "$STATE_DIR/getty-tty1-was-enabled"; then
        systemctl enable getty@tty1.service 2>/dev/null || true
        # `enable` only affects later boots. Give a machine uninstalled over
        # SSH an immediately usable local console after nucore.service stops.
        systemctl start getty@tty1.service 2>/dev/null || true
    fi
    if [ -s "$STATE_DIR/previous-default-target" ]; then
        PREVIOUS_TARGET=$(sed -n '1p' "$STATE_DIR/previous-default-target")
        case "$PREVIOUS_TARGET" in
            *.target) systemctl set-default "$PREVIOUS_TARGET" ;;
            *) echo "    invalid saved target '$PREVIOUS_TARGET'; leaving current target unchanged" >&2 ;;
        esac
    fi
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
      "$STATE_DIR/getty-tty1-was-enabled"
rmdir "$STATE_DIR" 2>/dev/null || true

echo "=== uninstall complete ==="
echo "All project-owned system changes made by install.sh were removed."
