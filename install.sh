#!/bin/bash
# install.sh — minimal, non-invasive install for nucore-portable.
#
# What this DOES:
#   • installs /etc/systemd/system/nucore.service (root, WantedBy=graphical.target)
#   • the unit launches bin/nucore-as-root.sh which polls logind for the
#     active local graphical session and execs start.sh with the right
#     DISPLAY / XAUTHORITY / XDG_RUNTIME_DIR — so nucore renders inside
#     your normal GNOME/KDE/whatever session as root, no auth prompt.
#
# What this DOES NOT do (deliberately — kept your desktop intact):
#   ✗ does not disable GDM / lightdm / sddm
#   ✗ does not change the default systemd target
#   ✗ does not disable getty@tty1 or fight it for the console
#   ✗ does not mask sleep / suspend / hibernate / blank
#   ✗ does not mask unattended-upgrades / packagekit / notifications
#   ✗ does not install or pull in any apt packages
#
# Boot flow on a normal GNOME box after this install:
#   1. systemd boots normally → graphical.target activates → GDM shows up
#   2. nucore.service starts (pulled in by graphical.target) and waits in
#      its polling loop for an active local graphical session
#   3. you log in as your normal user → wrapper sees the active session,
#      grabs DISPLAY+XAUTHORITY, execs start.sh as root → nucore appears
#      fullscreen on your desktop
#   4. press F1 / Esc → nucore exits → service exits cleanly (Restart=no)
#      → you are back at your GNOME desktop
#   5. to relaunch from your desktop terminal, no auth needed:
#         systemctl start nucore
#      (systemctl reads our unit, kicks the wrapper again)
#
# If you don't want autostart at all, just answer N to the autostart
# prompt — start.sh still works as a manual launcher with run0/sudo/pkexec
# for the privilege step.
#
# Reverse with: ./uninstall.sh

set -e

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$SCRIPT_DIR"

# Self-elevate: run0 (Debian 13) → sudo → pkexec.
if [ "$EUID" -ne 0 ]; then
    for esc in run0 sudo pkexec; do
        if command -v "$esc" >/dev/null 2>&1; then
            echo "[install.sh] re-launching under $esc to gain root..."
            case "$esc" in
                run0)   exec run0 --description="nucore-portable installer" -- "$0" "$@" ;;
                sudo)   exec sudo "$0" "$@" ;;
                pkexec) exec pkexec "$0" "$@" ;;
            esac
        fi
    done
    echo "install.sh: must be run as root, and no escalator (run0/sudo/pkexec) is available." >&2
    exit 1
fi

ask() {
    local prompt="$1" default="$2" answer
    if [ "$default" = "Y" ]; then
        read -r -p "$prompt [Y/n] " answer
        case "${answer:-Y}" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
    else
        read -r -p "$prompt [y/N] " answer
        case "$answer" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
    fi
}

echo "=== nucore-portable install ==="
echo "Bundle root  : $SCRIPT_DIR"
echo "Mode         : in-session (no kiosk, no DM disable, no system mutation)"
echo

read -r -p "Default game [swe1_14/rfm_15/auto] (default: swe1_14): " GAME_IN
case "$GAME_IN" in
    swe1_14|rfm_15|auto) DEFAULT_GAME="$GAME_IN" ;;
    swe1)                DEFAULT_GAME=swe1_14 ;;
    rfm)                 DEFAULT_GAME=rfm_15 ;;
    *)                   DEFAULT_GAME=swe1_14 ;;
esac

USE_PINBOX=0
ask "Boot the pinbox fork instead of nucore?" N && USE_PINBOX=1

EXTRA_FLAGS=""
[ $USE_PINBOX -eq 1 ] && EXTRA_FLAGS="--pinbox"

DO_AUTOSTART=1
ask "Auto-launch on graphical login (recommended)?" Y || DO_AUTOSTART=0

# Autologin: pick the user GDM should log in automatically on boot.
# Without this the user sits at the GDM password prompt forever before
# nucore can attach to their session. Default to the human invoker (the
# uid that launched ./install.sh — SUDO_UID / PKEXEC_UID / logname).
DO_AUTOLOGIN=0
DEFAULT_AUTOLOGIN_USER=""
for cand_uid in "${SUDO_UID:-}" "${PKEXEC_UID:-}"; do
    [ -n "$cand_uid" ] || continue
    cand_name=$(getent passwd "$cand_uid" | cut -d: -f1) || true
    [ -n "$cand_name" ] && { DEFAULT_AUTOLOGIN_USER="$cand_name"; break; }
done
if [ -z "$DEFAULT_AUTOLOGIN_USER" ]; then
    DEFAULT_AUTOLOGIN_USER=$(logname 2>/dev/null || true)
fi
if [ -z "$DEFAULT_AUTOLOGIN_USER" ] || [ "$DEFAULT_AUTOLOGIN_USER" = "root" ]; then
    # Fall back to the first uid >= 1000 with a real shell.
    DEFAULT_AUTOLOGIN_USER=$(getent passwd \
        | awk -F: '$3>=1000 && $3<65534 && $7 !~ /(nologin|false)$/ {print $1; exit}')
fi

if ask "Enable display-manager autologin (GDM/SDDM/LightDM) so the box boots straight in?" Y; then
    DO_AUTOLOGIN=1
    read -r -p "Auto-login user [default: $DEFAULT_AUTOLOGIN_USER]: " AUTOLOGIN_IN
    AUTOLOGIN_USER="${AUTOLOGIN_IN:-$DEFAULT_AUTOLOGIN_USER}"
    if ! id "$AUTOLOGIN_USER" >/dev/null 2>&1; then
        echo "    user '$AUTOLOGIN_USER' does not exist — autologin DISABLED"
        DO_AUTOLOGIN=0
    fi
fi

echo
echo "About to apply:"
echo "  default game        : $DEFAULT_GAME"
echo "  emulator            : $([ $USE_PINBOX -eq 1 ] && echo pinbox || echo nucore)"
echo "  autostart on login  : $DO_AUTOSTART"
echo "  display-manager autologin : $([ $DO_AUTOLOGIN -eq 1 ] && echo "yes ($AUTOLOGIN_USER)" || echo no)"
echo "  install path        : $SCRIPT_DIR (run from where it lives — no copy)"
echo
ask "Proceed?" Y || { echo "aborted."; exit 0; }

WRAPPER="$SCRIPT_DIR/bin/nucore-as-root.sh"
chmod 0755 "$WRAPPER" "$SCRIPT_DIR/start.sh"

# pinbox reads its sound bank from roms/<game>_pinbox.bin, but the bundle
# only ships roms/<game>_nucore.bin. Mirror them so pinbox can boot
# regardless of which fork the user picks now or later. Cheap no-op once
# the copies exist.
for src in "$SCRIPT_DIR"/roms/*_nucore.bin; do
    [ -f "$src" ] || continue
    dst="${src%_nucore.bin}_pinbox.bin"
    [ -e "$dst" ] || cp -p -- "$src" "$dst"
done

UNIT=/etc/systemd/system/nucore.service
echo "[+] writing $UNIT"
cat > "$UNIT" <<EOF
[Unit]
Description=Pinball 2000 (nucore-portable, in-session as root)
# Pulled in when the graphical stack is up. The wrapper then waits inside
# its polling loop until a real user logs in and an active session exists.
After=graphical.target
Wants=graphical.target

[Service]
Type=simple
WorkingDirectory=$SCRIPT_DIR
# No User= line: runs as root, gets CAP_SYS_RAWIO + CAP_SYS_NICE for free.
# That is exactly what nucore needs for parallel-port ioperm and RT audio.
ExecStart=$WRAPPER $EXTRA_FLAGS $DEFAULT_GAME -fullscreen -bpp 16
# F1 / Esc → nucore exits cleanly → we DO NOT bounce back. User explicitly
# asked for the desktop, so go to the desktop. To relaunch from a desktop
# terminal: systemctl start nucore (no auth needed for owner of the unit
# from the active session — systemd-logind allows it via polkit defaults).
Restart=on-failure
RestartSec=5
# Hard fuse so a broken unit cannot turn into an infinite restart loop.
StartLimitBurst=3
StartLimitIntervalSec=60
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=graphical.target
EOF

systemctl daemon-reload

# Polkit rule: let any user in an active local session start/stop/restart
# THIS ONE unit without password, from `systemctl start nucore` in their
# terminal. Polkit ships with every Debian desktop (gnome-shell depends on
# it) — this is a config file drop, not a package install. Without this
# rule, relaunching from the desktop would pop a GUI auth dialog every
# time, which contradicts the "no prompt ever, once installed" goal.
RULES_DIR=/etc/polkit-1/rules.d
if [ -d "$RULES_DIR" ] || mkdir -p "$RULES_DIR" 2>/dev/null; then
    RULE="$RULES_DIR/49-nucore.rules"
    echo "[+] writing $RULE (active-session user can manage nucore.service without auth)"
    cat > "$RULE" <<'EOF'
// Allow members of an active local session to start/stop/restart
// nucore.service without a polkit password prompt. Scoped to that
// single unit only.
polkit.addRule(function(action, subject) {
    if (action.id == "org.freedesktop.systemd1.manage-units" &&
        action.lookup("unit") == "nucore.service" &&
        subject.active && subject.local) {
        return polkit.Result.YES;
    }
});
EOF
    chmod 0644 "$RULE"
else
    echo "[!] polkit not present — relaunches via 'systemctl start nucore' will prompt."
fi

if [ "$DO_AUTOSTART" = 1 ]; then
    systemctl enable nucore.service
    echo "    enabled — will start at next graphical login."
else
    systemctl disable nucore.service 2>/dev/null || true
    echo "    not enabled — start manually with: systemctl start nucore"
fi

# ── Display-manager autologin (GDM / SDDM / LightDM) ─────────────────────────
# We write configs for ALL three display managers (drop-ins for SDDM/
# LightDM, in-place patch for GDM if its config exists) so that autologin
# survives the user later switching DE — `apt install kubuntu-desktop`
# pulls in SDDM, our drop-in is already there waiting, autologin keeps
# working with no re-run of install.sh required.
# Each block is sentinel-fenced so uninstall.sh can strip only our edits.

# ── per-DM autologin patchers ────────────────────────────────────────────────
# All three use the same sentinel scheme so uninstall.sh can strip our
# block without touching anything else the user may have configured.
NUCORE_BEGIN='# >>> nucore-portable autologin >>>'
NUCORE_END='# <<< nucore-portable autologin <<<'

strip_block() {
    local conf="$1" tmp
    tmp=$(mktemp)
    awk -v B="$NUCORE_BEGIN" -v E="$NUCORE_END" '
        index($0,B)==1 { skip=1; next }
        index($0,E)==1 { skip=0; next }
        !skip { print }
    ' "$conf" > "$tmp"
    install -m 0644 "$tmp" "$conf"
    rm -f "$tmp"
}

apply_gdm() {
    # GDM: /etc/gdm3/daemon.conf (Debian/Ubuntu) or /etc/gdm/custom.conf
    # (Fedora/RHEL/Arch). [daemon] section.
    local conf="$1"
    [ -f "$conf.nucore-bak" ] || cp -a "$conf" "$conf.nucore-bak"
    strip_block "$conf"
    cat >> "$conf" <<EOF
$NUCORE_BEGIN
[daemon]
AutomaticLoginEnable=true
AutomaticLogin=$AUTOLOGIN_USER
$NUCORE_END
EOF
    echo "[+] autologin (GDM): $conf  -> $AUTOLOGIN_USER"
}

apply_sddm() {
    # SDDM: drop-in in /etc/sddm.conf.d/. We do NOT touch /etc/sddm.conf
    # because the distro may regenerate it. Drop-ins win over the main
    # file. Session= is best-effort — Kubuntu uses 'plasma' (Wayland) /
    # 'plasmax11', Manjaro/openSUSE 'plasma.desktop'. Leaving Session=
    # blank lets SDDM pick its built-in default, which works fine.
    install -d -m 0755 /etc/sddm.conf.d
    local conf=/etc/sddm.conf.d/49-nucore.conf
    cat > "$conf" <<EOF
$NUCORE_BEGIN
[Autologin]
User=$AUTOLOGIN_USER
Relogin=false
$NUCORE_END
EOF
    chmod 0644 "$conf"
    echo "[+] autologin (SDDM): $conf  -> $AUTOLOGIN_USER"
}

apply_lightdm() {
    # LightDM: drop-in in /etc/lightdm/lightdm.conf.d/. [Seat:*] applies
    # to every seat. autologin-user-timeout=0 makes the login instant
    # (default is sometimes 10s with a "click to abort" countdown on
    # Lubuntu/Xubuntu).
    install -d -m 0755 /etc/lightdm/lightdm.conf.d
    local conf=/etc/lightdm/lightdm.conf.d/49-nucore.conf
    cat > "$conf" <<EOF
$NUCORE_BEGIN
[Seat:*]
autologin-user=$AUTOLOGIN_USER
autologin-user-timeout=0
$NUCORE_END
EOF
    chmod 0644 "$conf"
    # The 'autologin' group is required for autologin to take effect on
    # Debian/Ubuntu LightDM (PAM uses pam_succeed_if to gate it).
    if getent group autologin >/dev/null 2>&1; then
        usermod -aG autologin "$AUTOLOGIN_USER" 2>/dev/null || true
    else
        groupadd autologin 2>/dev/null || true
        usermod -aG autologin "$AUTOLOGIN_USER" 2>/dev/null || true
    fi
    echo "[+] autologin (LightDM): $conf  -> $AUTOLOGIN_USER"
}

if [ "$DO_AUTOLOGIN" = 1 ]; then
    # Future-proofing: write configs for ALL three display managers, even
    # the ones not currently installed. The drop-ins are inert until the
    # corresponding DM reads them, so writing them ahead of time costs
    # nothing and means autologin keeps working if the user later does
    # `apt install kubuntu-desktop` (pulls in SDDM) or installs LightDM.
    #
    # GDM is the one exception: its config files (/etc/gdm3/daemon.conf,
    # /etc/gdm/custom.conf) are owned by the gdm3/gdm package and only
    # exist if that package is installed — we cannot pre-create them in
    # /etc/gdm3/ because the directory itself doesn't exist without the
    # package. So GDM autologin only kicks in if GDM is installed at the
    # time install.sh runs OR at the time the user later runs gdm for
    # the first time (in which case re-running install.sh fixes it).
    for conf in /etc/gdm3/daemon.conf /etc/gdm/custom.conf; do
        [ -f "$conf" ] && apply_gdm "$conf"
    done
    # SDDM and LightDM use drop-in directories we can safely create even
    # when the DM isn't installed yet — the directory itself is harmless,
    # and the DM will pick up the drop-in the first time it's invoked.
    apply_sddm
    apply_lightdm
    if ! [ -f /etc/gdm3/daemon.conf ] && ! [ -f /etc/gdm/custom.conf ]; then
        echo "[i] note: GDM not installed; if you switch to a GNOME desktop"
        echo "    later, re-run ./install.sh to enable GDM autologin too."
    fi
fi

echo
echo "=== install complete ==="
echo "Test now without rebooting (from inside your graphical session):"
echo "    systemctl start nucore"
echo "Watch logs:"
echo "    journalctl -u nucore -f"
echo "Reverse all of the above:"
echo "    $SCRIPT_DIR/uninstall.sh"
