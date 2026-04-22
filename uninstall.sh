#!/bin/bash
# uninstall.sh — reverse install.sh.
#
# Symmetric with the new install.sh: that script never touched GDM, getty,
# sleep targets, the default systemd target, or notification daemons, so
# this script never restores them either. The only artefacts to remove
# are the systemd unit and the daemon-reload that follows.
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
systemctl stop nucore.service    2>/dev/null || true
systemctl disable nucore.service 2>/dev/null || true
rm -f /etc/systemd/system/nucore.service
rm -f /etc/polkit-1/rules.d/49-nucore.rules
systemctl daemon-reload

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

echo "=== uninstall complete ==="
echo "Nothing else was changed by install.sh, so nothing else needs restoring."
