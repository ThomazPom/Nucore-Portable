#!/bin/bash
# Session-oriented cabinet installer.
set -euo pipefail

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
STATE=/var/lib/nucore-portable
CONF_DIR=/etc/nucore-portable
CONF=$CONF_DIR/session.conf
TTY=tty1
GRUB_DROPIN=/etc/default/grub.d/99-nucore-portable.cfg

ask() {
    local prompt=$1 default=$2 answer
    read -r -p "$prompt [$([ "$default" = Y ] && echo Y/n || echo y/N)] " answer
    [ "${answer:-$default}" = Y ] || [ "${answer:-$default}" = y ] ||
        [ "${answer:-$default}" = yes ] || [ "${answer:-$default}" = YES ]
}

case "${1:-}" in
    -h|--help)
        cat <<EOF
Usage: $ROOT/install.sh [BACKEND]

Backends:
  --display-manager   existing GDM, SDDM or LightDM (recommended when present)
  --gamescope         standalone Gamescope session
  --cage              standalone Cage kiosk session
  --weston            standalone Weston kiosk session
  --xorg              standalone minimal Xorg session
  --console           framebuffer / direct-display session
EOF
        exit 0 ;;
esac

if [ "$EUID" -ne 0 ]; then
    for tool in run0 sudo pkexec; do
        command -v "$tool" >/dev/null 2>&1 || continue
        case "$tool" in
            run0) exec run0 --description="nucore-portable installer" -- "$ROOT/install.sh" "$@" ;;
            *)    exec "$tool" "$ROOT/install.sh" "$@" ;;
        esac
    done
    echo "install.sh: root privileges are required" >&2; exit 1
fi

case "$ROOT/" in
    /tmp/*) echo "WARNING: $ROOT is volatile and may disappear at reboot." >&2
            ask "Continue from /tmp?" N || exit 2 ;;
esac

if [ -f "$STATE/install-mode" ]; then
    echo "install.sh: an existing cabinet integration is installed." >&2
    echo "Run ./uninstall.sh first, then run ./install.sh again." >&2
    exit 2
fi

dm_service=""
if systemctl cat display-manager.service >/dev/null 2>&1; then
    dm_service=$(readlink -f /etc/systemd/system/display-manager.service 2>/dev/null || true)
    [ -n "$dm_service" ] || dm_service=display-manager.service
fi
if [ -n "$dm_service" ]; then
    case "$dm_service" in *gdm*|*sddm*|*lightdm*) ;; *) dm_service="" ;; esac
fi

backend=""
case "${1:-}" in
    --display-manager|--desktop) backend=display-manager ;;
    --gamescope) backend=gamescope ;;
    --cage) backend=cage ;;
    --weston) backend=weston ;;
    --xorg|--xorg-only) backend=xorg ;;
    --console) backend=console ;;
    "") ;;
    *) echo "install.sh: unknown setup '$1'" >&2; exit 2 ;;
esac

if [ -z "$backend" ]; then
    echo "Which setup do you want to use?"
    choices=()
    if [ -n "$dm_service" ]; then
        choices+=(display-manager)
        echo "1. Existing display manager — Recommended"
    fi
    choices+=(gamescope cage weston xorg console)
    number=0
    for choice in "${choices[@]}"; do
        number=$((number + 1))
        [ "$choice" = display-manager ] && continue
        case "$choice" in
            gamescope) label=Gamescope ;; cage) label=Cage ;; weston) label=Weston ;;
            xorg) label=Xorg ;; console) label="Framebuffer / direct console" ;;
        esac
        printf '%d. %s\n' "$number" "$label"
    done
    if [ -n "$dm_service" ]; then
        echo
        echo "Recommended: autologin to the user's existing graphical session."
        echo "Its desktop and normal graphical stack remain installed and running."
    fi
    read -r -p "Setup [1]: " pick
    pick=${pick:-1}
    [[ "$pick" =~ ^[0-9]+$ ]] && [ "$pick" -ge 1 ] &&
        [ "$pick" -le "${#choices[@]}" ] || { echo "Invalid setup" >&2; exit 2; }
    backend=${choices[$((pick - 1))]}
fi

if [ "$backend" = display-manager ] && [ -z "$dm_service" ]; then
    echo "install.sh: no supported display manager is installed" >&2; exit 2
fi

default_user=""
for uid in "${SUDO_UID:-}" "${PKEXEC_UID:-}"; do
    [ -n "$uid" ] || continue
    default_user=$(getent passwd "$uid" | cut -d: -f1 || true)
    [ -n "$default_user" ] && break
done
[ -n "$default_user" ] || default_user=$(logname 2>/dev/null || true)
if [ -z "$default_user" ] || [ "$default_user" = root ]; then
    default_user=$(getent passwd | awk -F: '$3>=1000&&$3<65534&&$7!~/(nologin|false)$/ {print $1;exit}')
fi
read -r -p "Cabinet session user [${default_user}]: " session_user
session_user=${session_user:-$default_user}
session_uid=$(id -u "$session_user" 2>/dev/null) || { echo "Unknown user" >&2; exit 2; }
[ "$session_uid" -ge 1000 ] || { echo "Cabinet user must be unprivileged (UID >= 1000)" >&2; exit 2; }

checkout_writable=0
if command -v runuser >/dev/null 2>&1; then
    runuser -u "$session_user" -- test -w "$ROOT" && checkout_writable=1
    runuser -u "$session_user" -- test -w "$(dirname -- "$ROOT")" && checkout_writable=1
    if [ "$checkout_writable" -eq 0 ] &&
       [ -n "$(runuser -u "$session_user" -- find "$ROOT" -xdev -writable -print -quit 2>/dev/null)" ]; then
        checkout_writable=1
    fi
fi
if [ "$checkout_writable" -eq 1 ]; then
    echo >&2
    echo "SECURITY WARNING: $session_user can modify this checkout." >&2
    echo "The root service will execute code from it on boot." >&2
    echo "For a strict privilege boundary, install a root-owned checkout under /opt." >&2
    ask "Continue and trust this session user to modify Nucore Portable?" Y || exit 2
fi

echo
echo "Nucore launch configuration"
read -r -p "Nucore-Portable config file [none]: " portable_config
if [ -n "$portable_config" ]; then
    case "$portable_config" in /*) ;; *) portable_config="$ROOT/$portable_config" ;; esac
    portable_config=$(readlink -f -- "$portable_config") || {
        echo "install.sh: portable config does not exist" >&2; exit 2;
    }
    [ -f "$portable_config" ] || {
        echo "install.sh: portable config is not a regular file" >&2; exit 2;
    }
fi
read -r -p "Game [swe1_14/rfm_15/auto] (swe1_14): " game
game=${game:-swe1_14}
case "$game" in swe1|swe1_14) game=swe1_14;; rfm|rfm_15) game=rfm_15;; auto);; *) exit 2;; esac
flags=""
ask "Use Pinbox?" N && flags="$flags --pinbox"
ask "Enable production watchdog?" Y || flags="$flags --no-reboot"
sdl12_compat=0
sdl_display=auto
if [ "$backend" = cage ]; then
    echo "Cage is a native Wayland kiosk; SDL12-compat + Wayland is required."
    flags="$flags --sdl12-compat --wayland"
    sdl12_compat=1
    sdl_display=wayland
elif [ "$backend" = console ]; then
    echo "Direct console uses native SDL 1.2/fbcon; SDL2/KMSDRM is not offered."
elif ask "Use SDL12-compat?" N; then
    flags="$flags --sdl12-compat"
    sdl12_compat=1
    case "$backend" in
        display-manager|gamescope|weston)
            echo
            echo "SDL12-compat display path:"
            echo "1. Native Wayland"
            echo "2. Xwayland"
            read -r -p "Display path [1]: " display_pick
            case "${display_pick:-1}" in
                1|wayland) sdl_display=wayland; flags="$flags --wayland" ;;
                2|xwayland) sdl_display=xwayland; flags="$flags --xwayland" ;;
                *) echo "Invalid SDL display path" >&2; exit 2 ;;
            esac
            ;;
    esac
fi
ask "Use experimental ASIX libraries?" N && flags="$flags --asix"
if ask "Start fullscreen?" Y; then video=-fullscreen; else video=-window; fi
if [ "$backend" = console ]; then default_bpp=16; else default_bpp=32; fi
read -r -p "Colour depth [$default_bpp] (16/32): " bpp; bpp=${bpp:-$default_bpp}
case "$bpp" in 16|32);; *) echo "Expected 16 or 32" >&2; exit 2;; esac
service_args="${flags# } $game $video -bpp $bpp"
launch_args=()
[ -n "$portable_config" ] && launch_args+=(--config "$portable_config")
read -r -a guided_args <<< "$service_args"
launch_args+=("${guided_args[@]}")
[ "$backend" = console ] && launch_args=(--console "${launch_args[@]}")

maintenance=display-manager
[ -n "$dm_service" ] || maintenance=getty
if [ "$backend" != display-manager ]; then
    if [ -n "$dm_service" ]; then
        read -r -p "After Nucore exits [display-manager/getty] ($maintenance): " answer
        maintenance=${answer:-$maintenance}
    else
        echo "After Nucore exits: password-backed tty1 login (no display manager detected)."
        maintenance=getty
    fi
    case "$maintenance" in display-manager|getty);; *) exit 2;; esac
fi

quiet_boot=0
zero_grub_timeout=0
ask "Use the distribution's quiet boot presentation?" Y && quiet_boot=1
if command -v update-grub >/dev/null 2>&1; then
    ask "Hide the GRUB menu and use a zero-second timeout?" Y && zero_grub_timeout=1
fi

echo
echo "About to install:"
echo "  setup        : $backend"
echo "  session user : $session_user (no privileges required)"
echo "  launch       : $service_args"
[ "$sdl_display" = auto ] || echo "  SDL display  : $sdl_display"
echo "  config       : ${portable_config:-none}"
echo "  maintenance  : $maintenance"
ask "Proceed?" Y || exit 0

if [ "$sdl12_compat" -eq 1 ] && [ "$sdl_display" = wayland ] &&
   ! "$ROOT/bin/wayland-mesa.sh" check; then
    echo
    echo "Native SDL2 Wayland needs the optional 32-bit Mesa rendering pack."
    echo "It is excluded from the core repository because it expands to about 208 MiB."
    echo "The verified 49 MiB archive comes from this project's GitHub Releases."
    ask "Download and install the optional Wayland Mesa pack now?" Y || {
        echo "Choose Xwayland instead, or install it later with:" >&2
        echo "  $ROOT/bin/wayland-mesa.sh install" >&2
        exit 2
    }
    "$ROOT/bin/wayland-mesa.sh" install
fi

missing=()
case "$backend" in
    gamescope)
        command -v gamescope >/dev/null 2>&1 || [ -x /usr/games/gamescope ] || missing+=(gamescope)
        ;;
    cage)      command -v cage >/dev/null 2>&1 || missing+=(cage) ;;
    weston)    command -v weston >/dev/null 2>&1 || missing+=(weston) ;;
    xorg)
        command -v Xorg >/dev/null 2>&1 || missing+=(xserver-xorg-core)
        command -v xinit >/dev/null 2>&1 || missing+=(xinit)
        [ -e /usr/lib/xorg/modules/input/libinput_drv.so ] || missing+=(xserver-xorg-input-libinput)
        ;;
esac
if [ "$sdl12_compat" -eq 0 ] || [ "$sdl_display" = xwayland ]; then
    case "$backend" in
        gamescope|weston)
            command -v Xwayland >/dev/null 2>&1 || missing+=(xwayland)
            ;;
    esac
    case "$backend" in
        display-manager|gamescope|weston|xorg)
            command -v xhost >/dev/null 2>&1 || missing+=(x11-xserver-utils)
            ;;
    esac
fi
if [ "${#missing[@]}" -gt 0 ]; then
    echo "Missing distribution packages: ${missing[*]}"
    ask "Install them with APT?" Y || exit 2
    command -v apt-get >/dev/null 2>&1 || { echo "APT unavailable" >&2; exit 3; }
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${missing[@]}"
fi

install -d -m 0755 "$STATE" "$CONF_DIR"
[ -f "$STATE/previous-default-target" ] || systemctl get-default > "$STATE/previous-default-target"
[ -f "$STATE/getty-tty1-was-enabled" ] ||
    systemctl is-enabled getty@tty1.service > "$STATE/getty-tty1-was-enabled" 2>/dev/null || true
printf '%s\n' "$backend" > "$STATE/install-mode"

cat > "$CONF" <<EOF
# Managed by Nucore Portable
BACKEND=$backend
SESSION_USER=$session_user
SESSION_UID=$session_uid
MAINTENANCE=$maintenance
SDL12_COMPAT=$sdl12_compat
SDL_DISPLAY=$sdl_display
EOF
chmod 0644 "$CONF"
printf '%s\n' "${launch_args[@]}" > "$CONF_DIR/launch.args"
chmod 0644 "$CONF_DIR/launch.args"

chmod 0755 "$ROOT/start.sh" "$ROOT/bin/bundled.sh" \
    "$ROOT/bin/nucore-session.sh" "$ROOT/bin/nucore-service.sh"

if [ "$quiet_boot" -eq 1 ] || [ "$zero_grub_timeout" -eq 1 ]; then
    install -d -m 0755 /etc/default/grub.d
    if [ -e "$GRUB_DROPIN" ] &&
       ! grep -q '^# nucore-portable managed boot presentation$' "$GRUB_DROPIN"; then
        echo "install.sh: refusing unrelated existing $GRUB_DROPIN" >&2
        exit 3
    fi
    {
        echo '# nucore-portable managed boot presentation'
        if [ "$quiet_boot" -eq 1 ]; then
            cat <<'EOF'
for nucore_boot_arg in quiet loglevel=3 systemd.show_status=false rd.udev.log_level=3 vt.global_cursor_default=0; do
    case " $GRUB_CMDLINE_LINUX_DEFAULT " in
        *" $nucore_boot_arg "*) ;;
        *) GRUB_CMDLINE_LINUX_DEFAULT="$GRUB_CMDLINE_LINUX_DEFAULT $nucore_boot_arg" ;;
    esac
done
if command -v plymouth >/dev/null 2>&1; then
    case " $GRUB_CMDLINE_LINUX_DEFAULT " in *' splash '*) ;; *) GRUB_CMDLINE_LINUX_DEFAULT="$GRUB_CMDLINE_LINUX_DEFAULT splash" ;; esac
fi
unset nucore_boot_arg
EOF
        fi
        if [ "$zero_grub_timeout" -eq 1 ]; then
            cat <<'EOF'
GRUB_TIMEOUT_STYLE=hidden
GRUB_TIMEOUT=0
GRUB_RECORDFAIL_TIMEOUT=0
GRUB_THEME=""
GRUB_BACKGROUND=""
GRUB_TERMINAL_OUTPUT=console
EOF
        fi
    } > "$GRUB_DROPIN"
    chmod 0644 "$GRUB_DROPIN"
    update-grub
fi

if [ "$backend" = display-manager ]; then
    # The normal remembered desktop session supplies its own compositor and
    # publishes its display sockets through systemd --user.  Do not replace it
    # with a project-specific X11 or Wayland session.
    rm -f /usr/share/xsessions/nucore.desktop
    rm -f /usr/share/wayland-sessions/nucore.desktop
    rm -f /etc/systemd/system/getty@tty1.service.d/49-nucore-portable.conf
else
    rm -f /etc/xdg/autostart/nucore-cabinet.desktop
    install -d -m 0755 /etc/systemd/system/getty@tty1.service.d
    cat > /etc/systemd/system/getty@tty1.service.d/49-nucore-portable.conf <<EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin $session_user --login-options '-f $session_user -s $ROOT/bin/nucore-session.sh' --noclear %I \$TERM
TTYVTDisallocate=no
Restart=no
EOF
fi

# Configure autologin without replacing the user's remembered desktop session.
if [ "$backend" = display-manager ]; then
    case "$dm_service" in
        *gdm*)
            gdm_conf=/etc/gdm3/daemon.conf
            [ -f "$gdm_conf" ] || gdm_conf=/etc/gdm/custom.conf
            [ -f "$gdm_conf" ] || { echo "GDM config not found" >&2; exit 3; }
            sed -i '/^# >>> nucore-portable autologin >>>$/,/^# <<< nucore-portable autologin <<<$/{d}' "$gdm_conf"
            cat >> "$gdm_conf" <<EOF
# >>> nucore-portable autologin >>>
[daemon]
AutomaticLoginEnable=true
AutomaticLogin=$session_user
# <<< nucore-portable autologin <<<
EOF
            ;;
        *sddm*)
            install -d -m 0755 /etc/sddm.conf.d
            cat > /etc/sddm.conf.d/49-nucore.conf <<EOF
[Autologin]
User=$session_user
Relogin=false
EOF
            ;;
        *lightdm*)
            install -d -m 0755 /etc/lightdm/lightdm.conf.d
            cat > /etc/lightdm/lightdm.conf.d/49-nucore.conf <<EOF
[Seat:*]
autologin-user=$session_user
autologin-user-timeout=0
EOF
            ;;
        *) echo "Unsupported display manager: $dm_service" >&2; exit 3 ;;
    esac
fi

if [ "$backend" = display-manager ]; then
    unit_after="display-manager.service"
    unit_wants="display-manager.service"
    tty_directives="StandardInput=null"
    install_target=graphical.target
elif [ "$backend" = console ]; then
    unit_after="getty@tty1.service"
    unit_wants="getty@tty1.service"
    tty_directives="StandardInput=tty-force
TTYPath=/dev/$TTY
TTYReset=yes
TTYVTDisallocate=no"
    install_target=multi-user.target
else
    unit_after="getty@tty1.service"
    unit_wants="getty@tty1.service"
    tty_directives="StandardInput=null"
    install_target=multi-user.target
fi

cat > /etc/systemd/system/nucore.service <<EOF
[Unit]
Description=Pinball 2000 (Nucore Portable session architecture)
Documentation=file:$ROOT/README.md
After=systemd-user-sessions.service sound.target $unit_after
Wants=$unit_wants
StartLimitIntervalSec=60
StartLimitBurst=3

[Service]
Type=simple
WorkingDirectory=$ROOT
ExecStart="$ROOT/bin/nucore-service.sh"
Restart=no
$tty_directives
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=$install_target
EOF

systemctl daemon-reload
systemctl enable nucore.service
if [ "$backend" = display-manager ]; then
    systemctl set-default graphical.target
else
    systemctl unmask getty@tty1.service
    systemctl enable getty@tty1.service
    systemctl set-default multi-user.target
fi

echo
echo "Installed: real $session_user PAM/login session -> $backend -> root nucore.service"
echo "Next boot will use the new cabinet session architecture."
echo "Logs: journalctl -u nucore -f"
