#!/bin/bash
# Session-oriented cabinet installer.
set -euo pipefail

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
STATE=/var/lib/nucore-portable
CONF_DIR=/etc/nucore-portable
CONF=$CONF_DIR/session.conf
GRUB_DROPIN=/etc/default/grub.d/99-nucore-portable.cfg
GRUB_QUIET_SCRIPT=/etc/grub.d/01_nucore_portable_quiet
BACKPORTS_APT_SOURCE=/etc/apt/sources.list.d/nucore-portable-backports.sources
CABINET_USER=nucore-cabinet
CABINET_HOME=/var/lib/nucore-cabinet
CABINET_SHELL=/usr/local/libexec/nucore-cabinet-login
CABINET_WM=/usr/local/libexec/nucore-wm

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
  --console           framebuffer session (native SDL 1.2 / fbcon)
  --kmsdrm            direct DRM/KMS session (SDL12-compat / SDL2)
EOF
        exit 0 ;;
esac

if [ "$EUID" -ne 0 ]; then
    for tool in run0 pkexec sudo; do
        command -v "$tool" >/dev/null 2>&1 || continue
        [ "$tool" != run0 ] || command -v pkttyagent >/dev/null 2>&1 || continue
        case "$tool" in
            run0) exec run0 --description="nucore-portable installer" -- "$ROOT/install.sh" "$@" ;;
            *)    exec "$tool" "$ROOT/install.sh" "$@" ;;
        esac
    done
    echo "install.sh: root privileges are required" >&2
    echo "Install polkitd for run0, install pkexec, or run through sudo." >&2
    exit 1
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
    --kmsdrm) backend=kmsdrm ;;
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
    choices+=(gamescope cage weston xorg console kmsdrm)
    number=0
    for choice in "${choices[@]}"; do
        number=$((number + 1))
        [ "$choice" = display-manager ] && continue
        case "$choice" in
            gamescope) label=Gamescope ;; cage) label=Cage ;; weston) label=Weston ;;
            xorg) label=Xorg ;;
            console) label="Framebuffer — native SDL 1.2 / fbcon" ;;
            kmsdrm) label="KMSDRM — direct SDL2/DRM cabinet session" ;;
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
read -r -p "Maintenance/configuration user [${default_user}]: " owner_user
owner_user=${owner_user:-$default_user}
owner_uid=$(id -u "$owner_user" 2>/dev/null) || { echo "Unknown user" >&2; exit 2; }
[ "$owner_uid" -ge 1000 ] || { echo "Maintenance user must be unprivileged (UID >= 1000)" >&2; exit 2; }

checkout_writable=0
if command -v runuser >/dev/null 2>&1; then
    runuser -u "$owner_user" -- test -w "$ROOT" && checkout_writable=1
    runuser -u "$owner_user" -- test -w "$(dirname -- "$ROOT")" && checkout_writable=1
    if [ "$checkout_writable" -eq 0 ] &&
       [ -n "$(runuser -u "$owner_user" -- find "$ROOT" -xdev -writable -print -quit 2>/dev/null)" ]; then
        checkout_writable=1
    fi
fi
if [ "$checkout_writable" -eq 1 ]; then
    echo >&2
    echo "SECURITY WARNING: $owner_user can modify this checkout." >&2
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
echo
echo "The historical runner monitors Nucore and may restart it or hard-reboot the machine after a failure."
echo "Without it, Nucore Portable launches the no-watchdog binary directly; it can run normally and exits back to the configured maintenance path."
ask "Use the historical runner?" N || flags="$flags --no-runner"
sdl12_compat=0
sdl_display=auto
if [ "$backend" = cage ]; then
    echo "Cage is a native Wayland kiosk; SDL12-compat + Wayland is required."
    flags="$flags --sdl12-compat --wayland"
    sdl12_compat=1
    sdl_display=wayland
elif [ "$backend" = console ]; then
    echo "Framebuffer uses the proven native SDL 1.2 fbcon path."
elif [ "$backend" = kmsdrm ]; then
    echo "KMSDRM is a direct fullscreen cabinet backend with no display server or compositor."
    echo "It automatically enables SDL12-compat and the required 32-bit graphics runtime."
    flags="$flags --sdl12-compat --kmsdrm"
    sdl12_compat=1
    sdl_display=kmsdrm
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
if [ "$backend" = console ] || [ "$backend" = kmsdrm ]; then
    launch_args=(--console "${launch_args[@]}")
fi

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
console_640=0
if [ "$backend" = console ]; then
    if command -v update-grub >/dev/null 2>&1; then
        echo
        echo "GRUB and the kernel can request a 640x480 framebuffer."
        echo "Firmware, DRM/KMS, the GPU driver or the panel may refuse it and keep another mode."
        ask "Request a 640x480 framebuffer at boot?" Y && console_640=1
    else
        echo "update-grub is unavailable; framebuffer resolution will remain driver-selected." >&2
    fi
fi
ask "Use the distribution's quiet boot presentation?" Y && quiet_boot=1
if command -v update-grub >/dev/null 2>&1; then
    ask "Hide the GRUB menu and use a zero-second timeout?" Y && zero_grub_timeout=1
fi

echo
echo "About to install:"
echo "  setup        : $backend"
echo "  maintenance  : $owner_user (unchanged, no privileges added)"
[ "$backend" = display-manager ] || \
    echo "  cabinet login: $CABINET_USER (dedicated, locked, no sudo)"
echo "  launch       : $service_args"
[ "$sdl_display" = auto ] || echo "  SDL display  : $sdl_display"
echo "  config       : ${portable_config:-none}"
echo "  maintenance  : $maintenance"
[ "$backend" != console ] || \
    echo "  framebuffer  : $([ "$console_640" -eq 1 ] && echo 'request 640x480 (driver may refuse)' || echo 'driver-selected')"
ask "Proceed?" Y || exit 0

apt_source_created=0
cabinet_user_created=0
cleanup_failed_install() {
    local rc=$?
    trap - EXIT
    if [ "$rc" -ne 0 ] && [ "$apt_source_created" -eq 1 ]; then
        rm -f "$BACKPORTS_APT_SOURCE"
    fi
    if [ "$rc" -ne 0 ] && [ "$cabinet_user_created" -eq 1 ]; then
        userdel -r "$CABINET_USER" 2>/dev/null || true
        rm -f "$CABINET_SHELL"
    fi
    exit "$rc"
}
trap cleanup_failed_install EXIT

missing=()
needs_graphics_pack=0
if [ "$sdl12_compat" -eq 1 ] &&
   { [ "$sdl_display" = wayland ] || [ "$sdl_display" = kmsdrm ]; } &&
   ! "$ROOT/bin/wayland-mesa.sh" check; then
    needs_graphics_pack=1
    command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 || missing+=(curl)
    command -v xz >/dev/null 2>&1 || missing+=(xz-utils)
fi
# The cabinet lifecycle relies on logind inhibitors in every mode. The
# display-manager overview adapter additionally uses busctl and setpriv; both
# are ordinary systemd/util-linux infrastructure, not project daemons.
command -v systemd-inhibit >/dev/null 2>&1 || missing+=(systemd)
command -v busctl >/dev/null 2>&1 || missing+=(systemd)
command -v setpriv >/dev/null 2>&1 || missing+=(util-linux)
# The bundled 32-bit ALSA library still consumes the distribution's
# architecture-independent ALSA configuration. A stripped netinst does not
# necessarily contain it.
[ -r /usr/share/alsa/alsa.conf ] || missing+=(libasound2-data)

# A real login starts enabled user services, but a minimal Debian installation
# may contain no audio server at all. Reuse any PulseAudio or PipeWire stack
# already selected by the distribution; otherwise request Debian's maintained
# PipeWire audio set through the same generic package resolver.
if ! command -v pipewire >/dev/null 2>&1 &&
   ! command -v pulseaudio >/dev/null 2>&1; then
    missing+=(pipewire-audio)
fi
case "$backend" in
    gamescope)
        command -v gamescope >/dev/null 2>&1 || [ -x /usr/games/gamescope ] || missing+=(gamescope)
        # Gamescope is Vulkan-only. Debian marks Mesa's ICD as Recommended,
        # but this installer deliberately uses --no-install-recommends. Add it
        # when the host has no Vulkan implementation of its own (for example
        # a proprietary vendor ICD).
        compgen -G '/usr/share/vulkan/icd.d/*.json' >/dev/null || missing+=(mesa-vulkan-drivers)
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
        gamescope|weston|xorg)
            command -v xhost >/dev/null 2>&1 || missing+=(x11-xserver-utils)
            ;;
    esac
fi
if [ "${#missing[@]}" -gt 0 ]; then
    command -v apt-get >/dev/null 2>&1 || { echo "APT unavailable" >&2; exit 3; }

    # Commands can imply the same package through more than one backend rule.
    # Resolve every package independently so one missing candidate cannot hide
    # which part of the selected stack is unavailable.
    declare -A package_seen=()
    packages=()
    for package in "${missing[@]}"; do
        [ -n "${package_seen[$package]:-}" ] && continue
        package_seen[$package]=1
        packages+=("$package")
    done

    unavailable=()
    for package in "${packages[@]}"; do
        apt-get -s install "$package" >/dev/null 2>&1 || unavailable+=("$package")
    done

    if [ "${#unavailable[@]}" -gt 0 ]; then
        echo "Refreshing configured APT repositories before declaring packages unavailable..."
        DEBIAN_FRONTEND=noninteractive apt-get update
        unavailable=()
        for package in "${packages[@]}"; do
            apt-get -s install "$package" >/dev/null 2>&1 || unavailable+=("$package")
        done
    fi

    gamescope_from_backports=0
    backports_suite=""
    if [ "${#unavailable[@]}" -gt 0 ]; then
        distro_id=""; distro_codename=""
        if [ -r /etc/os-release ]; then
            distro_id=$(. /etc/os-release; printf '%s' "${ID:-}")
            distro_codename=$(. /etc/os-release; printf '%s' "${VERSION_CODENAME:-}")
        fi
        gamescope_unavailable=0
        for package in "${unavailable[@]}"; do
            [ "$package" != gamescope ] || gamescope_unavailable=1
        done
        if [ "$gamescope_unavailable" -eq 1 ] && [ "$distro_id" = debian ] &&
           [[ "$distro_codename" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
            backports_suite="${distro_codename}-backports"
            echo
            echo "Gamescope has no candidate in Debian $distro_codename's enabled suites."
            echo "The official $backports_suite suite is the Debian fallback for this backend."
            ask "Enable official Debian $backports_suite for Gamescope?" Y || exit 2
            if [ -e "$BACKPORTS_APT_SOURCE" ] &&
               ! grep -q '^# nucore-portable managed Debian backports$' "$BACKPORTS_APT_SOURCE"; then
                echo "install.sh: refusing unrelated $BACKPORTS_APT_SOURCE" >&2; exit 3
            fi
            if [ ! -e "$BACKPORTS_APT_SOURCE" ]; then
                apt_source_created=1
            fi
            # A marked file may be left from an earlier Debian release. It is
            # project-owned, so refresh it to the validated current codename;
            # never edit or replace an administrator-owned source file.
            cat > "$BACKPORTS_APT_SOURCE" <<EOF
# nucore-portable managed Debian backports
Types: deb
URIs: http://deb.debian.org/debian
Suites: $backports_suite
Components: main contrib
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF
            chmod 0644 "$BACKPORTS_APT_SOURCE"
            DEBIAN_FRONTEND=noninteractive apt-get update
            apt-get -s -t "$backports_suite" install gamescope >/dev/null 2>&1 &&
                gamescope_from_backports=1
        fi

        unavailable=()
        for package in "${packages[@]}"; do
            if [ "$package" = gamescope ] && [ "$gamescope_from_backports" -eq 1 ]; then
                apt-get -s -t "$backports_suite" install gamescope >/dev/null 2>&1 ||
                    unavailable+=("$package")
            else
                apt-get -s install "$package" >/dev/null 2>&1 || unavailable+=("$package")
            fi
        done
    fi

    if [ "${#unavailable[@]}" -gt 0 ]; then
        echo "install.sh: no installable candidate for: ${unavailable[*]}" >&2
        echo "Distribution: ${distro_id:-unknown} ${distro_codename:-unknown}" >&2
        echo "Enable an appropriate distribution repository or install those packages, then retry." >&2
        exit 3
    fi

    echo "Missing distribution packages: ${packages[*]}"
    ask "Install them with APT?" Y || exit 2
    regular_packages=()
    for package in "${packages[@]}"; do
        if [ "$package" != gamescope ] || [ "$gamescope_from_backports" -eq 0 ]; then
            regular_packages+=("$package")
        fi
    done
    if [ "${#regular_packages[@]}" -gt 0 ]; then
        DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
            "${regular_packages[@]}"
    fi
    if [ "$gamescope_from_backports" -eq 1 ]; then
        DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
            -t "$backports_suite" gamescope
    fi
fi

if [ "$needs_graphics_pack" -eq 1 ]; then
    echo
    echo "SDL2 $sdl_display needs the optional 32-bit Mesa rendering pack."
    echo "It is excluded from the core repository because it expands to about 211 MiB."
    echo "The verified 50 MiB archive comes from this project's GitHub Releases."
    ask "Download and install the optional SDL2 graphics pack now?" Y || {
        echo "Choose a hosted X11/Xwayland backend instead, or install it later with:" >&2
        echo "  $ROOT/bin/wayland-mesa.sh install" >&2
        exit 2
    }
    "$ROOT/bin/wayland-mesa.sh" install
fi

session_user=$owner_user
session_uid=$owner_uid
if [ "$backend" != display-manager ]; then
    if getent passwd "$CABINET_USER" >/dev/null; then
        echo "install.sh: reserved account '$CABINET_USER' already exists" >&2
        echo "Remove that unrelated account or choose display-manager mode." >&2
        exit 3
    fi
    install -d -m 0755 "$(dirname -- "$CABINET_SHELL")"
    # The dedicated account must not need traversal access to the owner's
    # home directory. Install only the small session host and Xorg helper in a
    # system path; the privileged Nucore service continues to run the actual
    # checkout in place.
    install -m 0755 "$ROOT/bin/nucore-session.sh" "$CABINET_SHELL"
    install -m 0755 "$ROOT/bin/nucore-wm" "$CABINET_WM"
    useradd --create-home --home-dir "$CABINET_HOME" --user-group \
        --shell "$CABINET_SHELL" "$CABINET_USER"
    passwd --lock "$CABINET_USER" >/dev/null
    cabinet_user_created=1
    session_user=$CABINET_USER
    session_uid=$(id -u "$CABINET_USER")
    session_gid=$(id -g "$CABINET_USER")
    install -m 0600 -o "$session_uid" -g "$session_gid" /dev/null "$CABINET_HOME/.hushlogin"
fi

install -d -m 0755 "$STATE" "$CONF_DIR"
[ -f "$STATE/previous-default-target" ] || systemctl get-default > "$STATE/previous-default-target"
[ -f "$STATE/getty-tty1-was-enabled" ] ||
    systemctl is-enabled getty@tty1.service > "$STATE/getty-tty1-was-enabled" 2>/dev/null || true
printf '%s\n' "$backend" > "$STATE/install-mode"
[ "$cabinet_user_created" -eq 0 ] || printf '%s\n' "$CABINET_USER" > "$STATE/cabinet-user-created"

apt_source_created=0

cat > "$CONF" <<EOF
# Managed by Nucore Portable
BACKEND=$backend
SESSION_USER=$session_user
SESSION_UID=$session_uid
OWNER_USER=$owner_user
MAINTENANCE=$maintenance
SDL12_COMPAT=$sdl12_compat
SDL_DISPLAY=$sdl_display
EOF
chmod 0644 "$CONF"
printf '%s\n' "${launch_args[@]}" > "$CONF_DIR/launch.args"
chmod 0644 "$CONF_DIR/launch.args"

chmod 0755 "$ROOT/start.sh" "$ROOT/bin/bundled.sh" \
    "$ROOT/bin/nucore-session.sh" "$ROOT/bin/nucore-service.sh"

if [ "$quiet_boot" -eq 1 ] || [ "$zero_grub_timeout" -eq 1 ] ||
   [ "$console_640" -eq 1 ]; then
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
        if [ "$console_640" -eq 1 ]; then
            cat <<'EOF'
# Best-effort direct-console mode request. GRUB has a safe automatic fallback,
# and the kernel display driver remains free to reject an unsupported mode.
GRUB_GFXMODE=640x480,auto
GRUB_GFXPAYLOAD_LINUX=keep
GRUB_TERMINAL_OUTPUT=gfxterm
case " $GRUB_CMDLINE_LINUX_DEFAULT " in
    *' video=640x480 '*) ;;
    *) GRUB_CMDLINE_LINUX_DEFAULT="$GRUB_CMDLINE_LINUX_DEFAULT video=640x480" ;;
esac
EOF
        fi
    } > "$GRUB_DROPIN"
    chmod 0644 "$GRUB_DROPIN"

    if [ "$quiet_boot" -eq 1 ]; then
        if [ -e "$GRUB_QUIET_SCRIPT" ] &&
           ! grep -q '^# nucore-portable managed silent GRUB handoff$' "$GRUB_QUIET_SCRIPT"; then
            echo "install.sh: refusing unrelated existing $GRUB_QUIET_SCRIPT" >&2
            exit 3
        fi
        cat > "$GRUB_QUIET_SCRIPT" <<'EOF'
#!/bin/sh
# nucore-portable managed silent GRUB handoff
cat <<'GRUB_EOF'
if [ "${recordfail}" != 1 ]; then
  # GRUB's Debian generator always emits two kernel/initrd loading messages.
  # Hide ordinary terminal text without hiding the separately coloured menu.
  set color_normal=black/black
fi
GRUB_EOF
EOF
        chmod 0755 "$GRUB_QUIET_SCRIPT"
    else
        rm -f "$GRUB_QUIET_SCRIPT"
    fi
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
    getty_dropin_tmp=$(mktemp /etc/systemd/system/getty@tty1.service.d/.49-nucore-portable.conf.XXXXXX)
    cat > "$getty_dropin_tmp" <<EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin $CABINET_USER --noissue --noclear %I \$TERM
Restart=no
TimeoutStopSec=10
TTYVTDisallocate=no
StandardOutput=journal
StandardError=journal
EOF
    chmod 0644 "$getty_dropin_tmp"
    mv -f "$getty_dropin_tmp" /etc/systemd/system/getty@tty1.service.d/49-nucore-portable.conf
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
AutomaticLogin=$owner_user
# <<< nucore-portable autologin <<<
EOF
            ;;
        *sddm*)
            install -d -m 0755 /etc/sddm.conf.d
            cat > /etc/sddm.conf.d/49-nucore.conf <<EOF
[Autologin]
User=$owner_user
Relogin=false
EOF
            ;;
        *lightdm*)
            install -d -m 0755 /etc/lightdm/lightdm.conf.d
            cat > /etc/lightdm/lightdm.conf.d/49-nucore.conf <<EOF
[Seat:*]
autologin-user=$owner_user
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
else
    # The real PAM/login session owns tty1 for every standalone backend.
    # Native SDL fbcon opens fb0 and allocates its own VT; forcing tty1 into
    # the separate root service races login and causes systemd to deliver HUP.
    unit_after="getty@tty1.service"
    unit_wants="getty@tty1.service"
    tty_directives="StandardInput=null"
    install_target=multi-user.target
fi

service_tmp=$(mktemp /etc/systemd/system/.nucore.service.XXXXXX)
cat > "$service_tmp" <<EOF
[Unit]
Description=Pinball 2000 (Nucore Portable session architecture)
Documentation=file:$ROOT/README.md
After=systemd-user-sessions.service sound.target $unit_after
${unit_wants:+Wants=$unit_wants}
StartLimitIntervalSec=60
StartLimitBurst=3

[Service]
Type=simple
WorkingDirectory=$ROOT
ExecStart="$ROOT/bin/nucore-service.sh"
Restart=no
KillMode=control-group
TimeoutStopSec=15
$tty_directives
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=$install_target
EOF

test -s "$service_tmp"
chmod 0644 "$service_tmp"
mv -f "$service_tmp" /etc/systemd/system/nucore.service
test -s /etc/systemd/system/nucore.service
[ "$backend" = display-manager ] ||
    test -s /etc/systemd/system/getty@tty1.service.d/49-nucore-portable.conf

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
echo "Installed: $session_user PAM/logind session -> $backend -> root nucore.service"
echo "Next boot will use the new cabinet session architecture."
echo "Logs: journalctl -u nucore -f"
