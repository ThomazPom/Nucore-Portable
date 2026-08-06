#!/bin/bash
# install.sh — scoped, reversible cabinet integration for Nucore-Portable.
#
# Profiles:
#   xorg-only (recommended)  minimal Xorg and Nucore on tty1; no desktop
#   desktop                  attach Nucore to an existing graphical session
#   console                  native SDL fbcon, no scaler (advanced/legacy)
#
# The installer never installs a desktop environment.  Xorg-only may offer to
# install just Xorg, xinit and the libinput Xorg driver when they are missing.
# Reverse project-owned changes with ./uninstall.sh.

set -e

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$SCRIPT_DIR"

INSTALL_MODE=""
INSTALL_MODE_ARG=""
case "${1:-}" in
    --xorg-only) INSTALL_MODE=xorg-only; INSTALL_MODE_ARG=--xorg-only; shift ;;
    --desktop)   INSTALL_MODE=desktop;   INSTALL_MODE_ARG=--desktop; shift ;;
    --console)   INSTALL_MODE=console;   INSTALL_MODE_ARG=--console; shift ;;
    -h|--help)
        cat <<EOF
Usage: $0 [--xorg-only|--desktop|--console]

  --xorg-only  dedicated cabinet: minimal Xorg + Nucore (recommended)
  --desktop    launch in an existing GNOME/KDE/etc. session
  --console    direct SDL fbcon, no scaling (advanced/legacy)
EOF
        exit 0 ;;
    "") ;;
    *) echo "install.sh: unknown option '$1'" >&2; exit 2 ;;
esac
[ "$#" -eq 0 ] || { echo "install.sh: unexpected arguments: $*" >&2; exit 2; }

# Self-elevate: run0 (Debian 13) → sudo → pkexec.
if [ "$EUID" -ne 0 ]; then
    REEXEC_ARGS=()
    [ -n "$INSTALL_MODE_ARG" ] && REEXEC_ARGS+=("$INSTALL_MODE_ARG")
    for esc in run0 sudo pkexec; do
        if command -v "$esc" >/dev/null 2>&1; then
            echo "[install.sh] re-launching under $esc to gain root..."
            case "$esc" in
                run0)   exec run0 --description="nucore-portable installer" -- "$0" "${REEXEC_ARGS[@]}" ;;
                sudo)   exec sudo "$0" "${REEXEC_ARGS[@]}" ;;
                pkexec) exec pkexec "$0" "${REEXEC_ARGS[@]}" ;;
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

case "$SCRIPT_DIR/" in
    /tmp/*)
        cat >&2 <<EOF

WARNING: this checkout is below /tmp:
  $SCRIPT_DIR

The installer does not copy the bundle. The service points to this exact
directory, which may disappear at reboot.
EOF
        ask "Continue installing from volatile /tmp anyway?" N || exit 2
        ;;
esac

if [ -z "$INSTALL_MODE" ]; then
    cat <<EOF
Installation profile:
  1. xorg-only  minimal Xorg + Nucore, dedicated cabinet (recommended)
  2. desktop    use an existing graphical desktop
  3. console    direct fbcon, native SDL only, no scaling (advanced)
EOF
    read -r -p "Profile [1]: " MODE_IN
    case "${MODE_IN:-1}" in
        1|xorg-only|xorg|cabinet) INSTALL_MODE=xorg-only ;;
        2|desktop|graphical)      INSTALL_MODE=desktop ;;
        3|console|fbcon)          INSTALL_MODE=console ;;
        *) echo "install.sh: expected 1, 2 or 3" >&2; exit 2 ;;
    esac
fi

if [ "$INSTALL_MODE" = console ]; then
    cat <<'EOF'

DIRECT CONSOLE MODE IS ADVANCED AND PROVIDES NO SCALING.
Use it only with a display path already proven to present 640x480 correctly
(for example an arcade CRT, ArcadeVGA, or a monitor with its own scaler).
SDL12-compat is not supported in this profile.
The installed service always requests Nucore fullscreen at 16 bpp: this is the
legacy framebuffer path Nucore was designed for. These command-line values
override FULL_SCREEN and BPP_ADJ from config/pb2k.cfg at boot.
EOF
    read -r -p "Type DIRECT CONSOLE to continue: " CONSOLE_ACK
    [ "$CONSOLE_ACK" = "DIRECT CONSOLE" ] || { echo "Console install aborted."; exit 2; }
fi

STATE_DIR=/var/lib/nucore-portable
if [ -f "$STATE_DIR/install-mode" ]; then
    EXISTING_MODE=$(sed -n '1p' "$STATE_DIR/install-mode")
    if [ "$EXISTING_MODE" != "$INSTALL_MODE" ]; then
        echo "install.sh: '$EXISTING_MODE' is already installed." >&2
        echo "Run ./uninstall.sh before switching to '$INSTALL_MODE'." >&2
        exit 2
    fi
fi

echo "=== nucore-portable install ==="
echo "Bundle root  : $SCRIPT_DIR"
echo "Profile      : $INSTALL_MODE"
echo

PORTABLE_CONFIG=""
PORTABLE_CONFIG_WORDS=""
cat <<'EOF'
CONFIGURATION SOURCE
Leave this blank for the guided questions below. Alternatively, enter a
Nucore-Portable command-line config containing the complete launcher/game
selection; the installer will load it first and still append the selected
profile's explicit video mode afterward.
EOF
read -r -p "Nucore-Portable command-line config (blank: none): " CONFIG_IN
if [ -n "$CONFIG_IN" ]; then
    case "$CONFIG_IN" in
        /*) PORTABLE_CONFIG="$CONFIG_IN" ;;
        *)  PORTABLE_CONFIG="$SCRIPT_DIR/$CONFIG_IN" ;;
    esac
    PORTABLE_CONFIG=$(readlink -f -- "$PORTABLE_CONFIG") || {
        echo "install.sh: portable config does not exist" >&2; exit 2;
    }
    [ -f "$PORTABLE_CONFIG" ] || {
        echo "install.sh: portable config is not a regular file: $PORTABLE_CONFIG" >&2; exit 2;
    }
    if ! PORTABLE_CONFIG_WORDS=$(sed '/^[[:space:]]*#/d; /^[[:space:]]*$/d' "$PORTABLE_CONFIG" \
        | xargs -n1 printf '%s\n'); then
        echo "install.sh: cannot parse portable config: $PORTABLE_CONFIG" >&2
        exit 2
    fi
    if [ "$INSTALL_MODE" = console ] &&
       printf '%s\n' "$PORTABLE_CONFIG_WORDS" | grep -Fxq -- --sdl12-compat; then
        echo "install.sh: console profile cannot use --sdl12-compat from $PORTABLE_CONFIG" >&2
        exit 2
    fi
    case "$PORTABLE_CONFIG" in
        *[!A-Za-z0-9_./-]*)
            echo "install.sh: installed config path contains unsupported characters: $PORTABLE_CONFIG" >&2
            exit 2 ;;
    esac
fi

DEFAULT_GAME=swe1_14
USE_PINBOX=0
USE_NO_REBOOT=0
USE_SDL12_COMPAT=0
USE_ASIX=0
if [ -z "$PORTABLE_CONFIG" ]; then
    cat <<'EOF'

EMULATOR SETUP
The production runner includes Nucore's cabinet watchdog. It can reboot the
computer after an emulator stall. Keep it for a finished cabinet; disable it
while commissioning unfamiliar hardware or configuration.
EOF
    ask "Enable the production watchdog?" Y || USE_NO_REBOOT=1

    read -r -p "Default game [swe1_14/rfm_15/auto] (default: swe1_14): " GAME_IN
    case "$GAME_IN" in
        "")                  ;;
        swe1_14|rfm_15|auto) DEFAULT_GAME="$GAME_IN" ;;
        swe1)                DEFAULT_GAME=swe1_14 ;;
        rfm)                 DEFAULT_GAME=rfm_15 ;;
        *) echo "install.sh: expected swe1_14, rfm_15 or auto" >&2; exit 2 ;;
    esac
    ask "Boot the pinbox fork instead of nucore?" N && USE_PINBOX=1

    if [ "$INSTALL_MODE" != console ]; then
        cat <<'EOF'

SDL IMPLEMENTATION
Native SDL 1.2 is the established default. SDL12-compat preserves Nucore's
SDL 1.2 interface but implements it over bundled SDL 2; it may integrate better
with modern displays, but remains an opt-in compatibility experiment.
EOF
        ask "Use SDL12-compat instead of native SDL 1.2?" N && USE_SDL12_COMPAT=1
    fi

    cat <<'EOF'

FTDI/USB LIBRARY
The original Nucore libftchipid path is the proven default and carries its old
libstdc++.so.5 dependency inside the bundle. The opt-in ASIX 0.1.0 path uses
libstdc++.so.6 and is newer, but has less real-cabinet validation.
EOF
    ask "Use the experimental newer ASIX library path?" N && USE_ASIX=1
fi

cat <<'EOF'

RUNTIME PROTECTION
The signal and audio shims stay enabled by default in every installation. Their
disable switches are diagnostic tools, not cabinet recommendations; advanced
users can place --no-audio-shim, --no-sigio-shim, or --no-shim in a Portable
config for a controlled A/B test.
EOF

VIDEO_ARGS=""
VIDEO_DESCRIPTION="use config/pb2k.cfg"
if [ "$INSTALL_MODE" = xorg-only ] || [ "$INSTALL_MODE" = desktop ]; then
    cat <<'EOF'

VIDEO SETUP
Fullscreen is recommended for a cabinet. 32 bpp is recommended on a graphical
display: Xorg/the desktop handles the physical monitor while Nucore gets its
expected surface. The selected values are appended to the service command line,
so they override old FULL_SCREEN/BPP_ADJ values in config/pb2k.cfg and any
earlier video option in the Portable config.
EOF
    if ask "Start Nucore fullscreen?" Y; then
        VIDEO_MODE=-fullscreen
        VIDEO_MODE_NAME=fullscreen
    else
        VIDEO_MODE=-window
        VIDEO_MODE_NAME=windowed
        echo "[!] Windowed mode is intended for diagnosis, not a finished cabinet."
    fi
    read -r -p "Nucore colour depth [32] (16 or 32): " VIDEO_BPP
    VIDEO_BPP=${VIDEO_BPP:-32}
    case "$VIDEO_BPP" in
        16|32) ;;
        *) echo "install.sh: colour depth must be 16 or 32" >&2; exit 2 ;;
    esac
    VIDEO_ARGS="$VIDEO_MODE -bpp $VIDEO_BPP"
    VIDEO_DESCRIPTION="$VIDEO_MODE_NAME, ${VIDEO_BPP} bpp (explicit service override)"
elif [ "$INSTALL_MODE" = console ]; then
    VIDEO_ARGS="-fullscreen -bpp 16"
    VIDEO_DESCRIPTION="fullscreen, 16 bpp (required console default)"
fi

EXTRA_FLAGS=""
[ $USE_PINBOX -eq 1 ] && EXTRA_FLAGS="--pinbox"
[ $USE_NO_REBOOT -eq 1 ] && EXTRA_FLAGS="$EXTRA_FLAGS --no-reboot"
[ $USE_SDL12_COMPAT -eq 1 ] && EXTRA_FLAGS="$EXTRA_FLAGS --sdl12-compat"
[ $USE_ASIX -eq 1 ] && EXTRA_FLAGS="$EXTRA_FLAGS --asix"
CONFIG_FLAG=""
[ -n "$PORTABLE_CONFIG" ] && CONFIG_FLAG="--config=$PORTABLE_CONFIG"

DO_AUTOSTART=1
if [ "$INSTALL_MODE" = desktop ]; then
    ask "Auto-launch on graphical login?" Y || DO_AUTOSTART=0
fi

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

if [ "$INSTALL_MODE" = desktop ] &&
   ask "Enable display-manager autologin (GDM/SDDM/LightDM) so the box boots straight in?" Y; then
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
echo "  portable config     : ${PORTABLE_CONFIG:-none}"
if [ -n "$PORTABLE_CONFIG" ]; then
    echo "  saved command line  : loaded first"
    echo "  config words        : $(printf '%s\n' "$PORTABLE_CONFIG_WORDS" | paste -sd' ' -)"
else
    echo "  default game        : $DEFAULT_GAME"
    echo "  emulator            : $([ $USE_PINBOX -eq 1 ] && echo pinbox || echo nucore)"
    echo "  watchdog            : $([ $USE_NO_REBOOT -eq 1 ] && echo disabled || echo production)"
    echo "  SDL                 : $([ $USE_SDL12_COMPAT -eq 1 ] && echo SDL12-compat || echo native SDL 1.2)"
    echo "  FTDI library        : $([ $USE_ASIX -eq 1 ] && echo 'ASIX 0.1.0 (experimental)' || echo 'original Nucore')"
fi
echo "  autostart on login  : $DO_AUTOSTART"
echo "  video               : $VIDEO_DESCRIPTION"
case "$INSTALL_MODE" in
    xorg-only)
        echo "  boot path           : multi-user.target -> tty1 -> minimal Xorg -> Nucore"
        echo "  maintenance fallback: display manager after Nucore/Xorg exits" ;;
    console)
        echo "  boot path           : multi-user.target -> tty1 -> native SDL fbcon"
        echo "  scaling             : none" ;;
    desktop)
        echo "  display-manager autologin : $([ $DO_AUTOLOGIN -eq 1 ] && echo "yes ($AUTOLOGIN_USER)" || echo no)" ;;
esac
echo "  install path        : $SCRIPT_DIR (run from where it lives — no copy)"
echo
ask "Proceed?" Y || { echo "aborted."; exit 0; }

WRAPPER="$SCRIPT_DIR/bin/nucore-as-root.sh"
XORG_WRAPPER="$SCRIPT_DIR/bin/nucore-xorg-only.sh"
chmod 0755 "$WRAPPER" "$XORG_WRAPPER" "$SCRIPT_DIR/start.sh" "$SCRIPT_DIR/bin/bundled.sh"

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
if [ -n "$PORTABLE_CONFIG" ]; then
    SERVICE_ARGS="$CONFIG_FLAG $VIDEO_ARGS"
else
    SERVICE_ARGS="$EXTRA_FLAGS $DEFAULT_GAME $VIDEO_ARGS"
fi

if [ "$INSTALL_MODE" != desktop ]; then
    if [ "$INSTALL_MODE" = xorg-only ]; then
        MISSING_XORG=()
        command -v Xorg >/dev/null 2>&1 || MISSING_XORG+=(xserver-xorg-core)
        command -v xinit >/dev/null 2>&1 || MISSING_XORG+=(xinit)
        [ -e /usr/lib/xorg/modules/input/libinput_drv.so ] || \
            MISSING_XORG+=(xserver-xorg-input-libinput)
        if [ "${#MISSING_XORG[@]}" -gt 0 ]; then
            echo "Minimal Xorg packages required: ${MISSING_XORG[*]}"
            ask "Install the minimal Xorg runtime now?" Y || exit 2
            command -v apt-get >/dev/null 2>&1 || {
                echo "install.sh: apt-get unavailable; install Xorg and xinit manually" >&2
                exit 3
            }
            DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
                "${MISSING_XORG[@]}"
        fi
    fi

    install -d -m 0755 "$STATE_DIR"
    if [ ! -f "$STATE_DIR/previous-default-target" ]; then
        systemctl get-default > "$STATE_DIR/previous-default-target"
    fi
    if [ ! -f "$STATE_DIR/getty-tty1-was-enabled" ]; then
        systemctl is-enabled getty@tty1.service > "$STATE_DIR/getty-tty1-was-enabled" 2>/dev/null || true
    fi
    printf '%s\n' "$INSTALL_MODE" > "$STATE_DIR/install-mode"

    if [ "$INSTALL_MODE" = xorg-only ]; then
        DESCRIPTION="minimal Xorg cabinet"
        EXEC_START="$XORG_WRAPPER $SERVICE_ARGS"
    else
        DESCRIPTION="direct fbcon cabinet (advanced)"
        EXEC_START="$SCRIPT_DIR/start.sh --console --no-root --no-inhibit $SERVICE_ARGS"
    fi

    echo "[+] writing $INSTALL_MODE $UNIT"
    cat > "$UNIT" <<EOF
[Unit]
Description=Pinball 2000 (nucore-portable, $DESCRIPTION)
Documentation=file:$SCRIPT_DIR/README.md
After=systemd-user-sessions.service getty-pre.target sound.target
Before=getty.target
Conflicts=display-manager.service getty@tty1.service
ConditionPathExists=/dev/tty0
StartLimitBurst=3
StartLimitIntervalSec=60

[Service]
Type=simple
WorkingDirectory=$SCRIPT_DIR
Environment=TERM=linux
ExecStart=$EXEC_START
Restart=no
StandardInput=tty-force
StandardOutput=journal+console
StandardError=journal+console
TTYPath=/dev/tty1
TTYReset=yes
TTYVHangup=yes
TTYVTDisallocate=yes
UtmpIdentifier=tty1

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl disable getty@tty1.service 2>/dev/null || true
    systemctl enable nucore.service
    systemctl set-default multi-user.target

    echo
    echo "=== $INSTALL_MODE install complete ==="
    if [ "$INSTALL_MODE" = xorg-only ]; then
        echo "Next boot: tty1 -> minimal Xorg -> Nucore."
        echo "If Nucore/Xorg exits, the display manager opens for maintenance."
    else
        echo "Next boot: tty1 -> native SDL fbcon (no scaling)."
    fi
    echo "Watch logs: journalctl -u nucore -f"
    echo "Reverse: $SCRIPT_DIR/uninstall.sh"
    exit 0
fi

install -d -m 0755 "$STATE_DIR"
printf '%s\n' desktop > "$STATE_DIR/install-mode"
echo "[+] writing $UNIT"
cat > "$UNIT" <<EOF
[Unit]
Description=Pinball 2000 (nucore-portable, in-session as root)
# Pulled in when the graphical stack is up. The wrapper then waits inside
# its polling loop until a real user logs in and an active session exists.
After=graphical.target
Wants=graphical.target
StartLimitBurst=3
StartLimitIntervalSec=60

[Service]
Type=simple
WorkingDirectory=$SCRIPT_DIR
# No User= line: runs as root, gets CAP_SYS_RAWIO + CAP_SYS_NICE for free.
# That is exactly what nucore needs for parallel-port ioperm and RT audio.
ExecStart=$WRAPPER $SERVICE_ARGS
# F1 / Esc → nucore exits cleanly → we DO NOT bounce back. User explicitly
# asked for the desktop, so go to the desktop. To relaunch from a desktop
# terminal: systemctl start nucore (no auth needed for owner of the unit
# from the active session — systemd-logind allows it via polkit defaults).
Restart=on-failure
RestartSec=5
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
