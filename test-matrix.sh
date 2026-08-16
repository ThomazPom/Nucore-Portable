#!/bin/bash
# Interactive visual cabinet matrix. This is a maintainer test, not an installer.
set -u

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
CASES=(
    gamescope-sdl1
    gamescope-sdl2-wayland
    gamescope-sdl2-xwayland
    cage-sdl2-wayland
    weston-sdl1
    weston-sdl2-wayland
    weston-sdl2-xwayland
    xorg-sdl1
    xorg-sdl2
    console-sdl1
    kmsdrm-sdl2
    display-manager-sdl1
    display-manager-sdl2-wayland
    display-manager-sdl2-xwayland
)
ONLY=""
DESKTOP=0
NO_BUNDLED_MESA=0

usage() {
    echo "Usage: $0 [--desktop] [--no-bundled-mesa] [--only:<case>]"
    echo
    echo "  --desktop  nest Gamescope/Cage/Weston in the current desktop and"
    echo "             test display-manager cases against its live session"
    echo "  --no-bundled-mesa"
    echo "             force SDL2 software rendering and disable bundled DRI"
    echo
    echo "Cases:"
    printf '  %s\n' "${CASES[@]}"
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        --desktop) DESKTOP=1 ;;
        --no-bundled-mesa) NO_BUNDLED_MESA=1 ;;
        --only:*)
            [ -z "$ONLY" ] || { echo "test-matrix.sh: --only specified twice" >&2; exit 2; }
            ONLY=${1#--only:}
            ;;
        *) echo "test-matrix.sh: unknown option '$1'" >&2; usage >&2; exit 2 ;;
    esac
    shift
done
if [ -n "$ONLY" ]; then
    valid=0
    for name in "${CASES[@]}"; do
        [ "$ONLY" != "$name" ] || valid=1
    done
    [ "$valid" -eq 1 ] || {
        echo "test-matrix.sh: unknown case '$ONLY'" >&2
        usage >&2
        exit 2
    }
fi
if [ "$DESKTOP" -eq 1 ]; then
    case "$ONLY" in
        xorg-*|console-*|kmsdrm-*)
            echo "test-matrix.sh: '$ONLY' requires the normal tty matrix" >&2
            exit 2
            ;;
    esac
fi

selected() {
    [ -z "$ONLY" ] || [ "$ONLY" = "$1" ]
}

CONF=/etc/nucore-portable/session.conf
ARGS=/etc/nucore-portable/launch.args
RUN_DIR=$(mktemp -d /tmp/nucore-visual-matrix.XXXXXX)
RESULTS="$RUN_DIR/results.txt"
SESSION_ENV=/run/user/$(id -u)/nucore-portable/display-environment
SERVICE_DROPIN=/run/systemd/system/nucore.service.d/90-visual-matrix.conf
SERVICE_UNIT=/etc/systemd/system/nucore.service
GETTY_MAINT=/run/systemd/system/getty@tty1.service.d/50-nucore-maintenance.conf
ORIGINAL_VT=$(fgconsole 2>/dev/null || echo 5)
DM_SERVICE=$(readlink -f /etc/systemd/system/display-manager.service 2>/dev/null || true)
GDM_CONF=""
NESTED_PID=""

case "$DM_SERVICE" in
    *gdm*)
        [ ! -f /etc/gdm3/daemon.conf ] || GDM_CONF=/etc/gdm3/daemon.conf
        [ -n "$GDM_CONF" ] || [ ! -f /etc/gdm/custom.conf ] || GDM_CONF=/etc/gdm/custom.conf
        ;;
esac

echo "Nucore Portable visual matrix"
echo "Each Pinbox run lasts at most 40 seconds. F1 may end it earlier."
[ "$DESKTOP" -eq 0 ] || echo "Host: current graphical desktop (no VT or display-manager changes)"
[ -z "$ONLY" ] || echo "Selected case: $ONLY"
echo "Results: $RESULTS"
echo
sudo -v || exit 1

HAD_CONF=0
HAD_ARGS=0
HAD_SERVICE=0
if sudo test -f "$CONF"; then
    HAD_CONF=1
    sudo install -m 0644 "$CONF" "$RUN_DIR/session.conf"
fi
if sudo test -f "$ARGS"; then
    HAD_ARGS=1
    sudo install -m 0644 "$ARGS" "$RUN_DIR/launch.args"
fi
sudo test ! -f "$SERVICE_UNIT" || HAD_SERVICE=1
if [ "$DESKTOP" -eq 0 ] && [ -n "$GDM_CONF" ]; then
    sudo install -m 0644 "$GDM_CONF" "$RUN_DIR/gdm.conf"
fi

restore() {
    timeout 10 sudo systemctl stop nucore.service 2>/dev/null || {
        sudo systemctl kill --kill-whom=all nucore.service 2>/dev/null || true
    }
    [ -z "$NESTED_PID" ] || kill "$NESTED_PID" 2>/dev/null || true
    [ -z "$NESTED_PID" ] || wait "$NESTED_PID" 2>/dev/null || true
    [ "$DESKTOP" -eq 1 ] || sudo systemctl stop display-manager.service 2>/dev/null || true
    if [ "$HAD_CONF" -eq 1 ]; then
        sudo install -m 0644 "$RUN_DIR/session.conf" "$CONF" 2>/dev/null || true
    else
        sudo rm -f "$CONF"
    fi
    if [ "$HAD_ARGS" -eq 1 ]; then
        sudo install -m 0644 "$RUN_DIR/launch.args" "$ARGS" 2>/dev/null || true
    else
        sudo rm -f "$ARGS"
    fi
    if [ "$DESKTOP" -eq 0 ] && [ -n "$GDM_CONF" ]; then
        sudo install -m 0644 "$RUN_DIR/gdm.conf" "$GDM_CONF" 2>/dev/null || true
    fi
    sudo rm -f "$SERVICE_DROPIN"
    [ "$HAD_SERVICE" -eq 1 ] || sudo rm -f "$SERVICE_UNIT"
    sudo rmdir /etc/nucore-portable /run/systemd/system/nucore.service.d 2>/dev/null || true
    sudo systemctl daemon-reload
    [ "$DESKTOP" -eq 1 ] || timeout 5 sudo chvt "$ORIGINAL_VT" 2>/dev/null || true
    echo
    echo "Configuration restored. Results kept in $RESULTS"
}
trap restore EXIT
trap 'exit 130' INT TERM

# The matrix is also a checkout-level test tool. If the cabinet integration is
# not installed, create only the minimal, non-enabled system files required by
# the root service. The EXIT trap removes them again.
if [ "$HAD_CONF" -eq 0 ]; then
    printf '%s\n' '# Temporary Nucore Portable visual matrix configuration' \
        'BACKEND=display-manager' "SESSION_USER=$(id -un)" \
        "SESSION_UID=$(id -u)" 'MAINTENANCE=tty' \
        'SDL12_COMPAT=0' 'SDL_DISPLAY=auto' >"$RUN_DIR/session.conf.new"
    sudo install -d -m 0755 /etc/nucore-portable
    sudo install -m 0644 "$RUN_DIR/session.conf.new" "$CONF"
fi
if [ "$HAD_ARGS" -eq 0 ]; then
    printf '%s\n' '--pinbox' >"$RUN_DIR/launch.args.new"
    sudo install -d -m 0755 /etc/nucore-portable
    sudo install -m 0644 "$RUN_DIR/launch.args.new" "$ARGS"
fi
if [ "$HAD_SERVICE" -eq 0 ]; then
    {
        printf '%s\n' '[Unit]' 'Description=Pinball 2000 visual matrix (temporary)' \
            'After=systemd-user-sessions.service sound.target' '' \
            '[Service]' 'Type=simple' "WorkingDirectory=$ROOT" \
            "ExecStart=$ROOT/bin/nucore-service.sh" 'Restart=no' \
            'StandardInput=null' 'StandardOutput=journal' 'StandardError=journal'
    } >"$RUN_DIR/nucore.service.new"
    sudo install -m 0644 "$RUN_DIR/nucore.service.new" "$SERVICE_UNIT"
    sudo systemctl daemon-reload
fi

write_service_dropin() {
    local backend=$1 template
    sudo install -d -m 0755 /run/systemd/system/nucore.service.d
    if [ "$backend" = console ] || [ "$backend" = kmsdrm ]; then
        template="$RUN_DIR/console.conf"
        printf '%s\n' '[Service]' 'Environment=NUCORE_TEST_NO_MAINTENANCE=1' \
            'StandardInput=tty-force' 'TTYPath=/dev/tty1' \
            'TTYReset=yes' 'TTYVTDisallocate=no' >"$template"
    else
        template="$RUN_DIR/graphical.conf"
        printf '%s\n' '[Service]' 'Environment=NUCORE_TEST_NO_MAINTENANCE=1' \
            'StandardInput=null' >"$template"
    fi
    if [ "$NO_BUNDLED_MESA" -eq 1 ]; then
        printf '%s\n' 'Environment=SDL_RENDER_DRIVER=software' \
            'Environment=LIBGL_DRIVERS_PATH=/nonexistent' >>"$template"
    fi
    sudo install -m 0644 "$template" "$SERVICE_DROPIN"
    sudo systemctl daemon-reload
}

configure() {
    local backend=$1 compat=$2 display=$3
    sudo sed -i -e "s/^BACKEND=.*/BACKEND=$backend/" \
        -e "s/^SDL12_COMPAT=.*/SDL12_COMPAT=$compat/" \
        -e "s/^SDL_DISPLAY=.*/SDL_DISPLAY=$display/" "$CONF"
    sudo sed -i -e '/^--console$/d' -e '/^--sdl12-compat$/d' \
        -e '/^--wayland$/d' -e '/^--xwayland$/d' -e '/^--kmsdrm$/d' \
        -e '/^--no-reboot$/d' "$ARGS"
    sudo sed -i '1a --no-reboot' "$ARGS"
    [ "$compat" != 1 ] || sudo sed -i '1a --sdl12-compat' "$ARGS"
    case "$display" in
        wayland) sudo sed -i '1a --wayland' "$ARGS" ;;
        xwayland) sudo sed -i '1a --xwayland' "$ARGS" ;;
        kmsdrm) sudo sed -i '1a --kmsdrm' "$ARGS" ;;
    esac
    if [ "$backend" = console ] || [ "$backend" = kmsdrm ]; then
        sudo sed -i '1a --console' "$ARGS"
    fi
    write_service_dropin "$backend"
}

rate_case() {
    local name=$1 answer comment=""
    if [ "$DESKTOP" -eq 0 ]; then
        timeout 5 sudo chvt "$ORIGINAL_VT" 2>/dev/null || {
            echo "Cannot return to VT $ORIGINAL_VT safely; aborting." >&2
            return 2
        }
    fi
    echo
    read -r -p "$name: 1/OK or 2/KO: " answer
    case "${answer,,}" in
        1|ok) result=OK ;;
        2|ko) result=KO ;;
        *) result="NON NOTE" ;;
    esac
    read -r -p "Comment (optional): " comment
    printf '%s\t%s\t%s\n' "$name" "$result" "$comment" >>"$RESULTS"
}

run_service_for_40s() {
    local name=$1 i=0 invocation log="$RUN_DIR/$name.journal"
    # A transient checkout-level unit has no failed state on its first run.
    # Avoid a harmless but alarming diagnostic from reset-failed in that case.
    sudo systemctl reset-failed nucore.service 2>/dev/null || true
    sudo systemctl start nucore.service || return 1
    invocation=$(systemctl show nucore.service -p InvocationID --value)
    while [ "$i" -lt 400 ] && systemctl is-active --quiet nucore.service; do
        i=$((i + 1)); sleep 0.1
    done
    timeout 10 sudo systemctl stop nucore.service 2>/dev/null || {
        sudo systemctl kill --kill-whom=all nucore.service 2>/dev/null || true
    }
    journalctl _SYSTEMD_INVOCATION_ID="$invocation" --no-pager >"$log" 2>/dev/null || true
    grep -q 'Pinbox - 2.11' "$log" && grep -q 'Initialization complete!' "$log"
}

run_standalone() {
    local name=$1 backend=$2 compat=$3 display=$4 i=0 technical=FAIL
    echo "Starting $name..."
    sudo systemctl stop nucore.service 2>/dev/null || true
    configure "$backend" "$compat" "$display"
    sudo rm -f "$GETTY_MAINT" "$SESSION_ENV" \
        /run/user/$(id -u)/nucore-portable/environment.* 2>/dev/null || true
    sudo systemctl daemon-reload
    sudo systemctl restart getty@tty1.service
    timeout 5 sudo chvt 1 || { echo "Could not activate tty1"; return 1; }
    while [ "$i" -lt 300 ] && [ ! -f "$SESSION_ENV" ]; do i=$((i + 1)); sleep 0.1; done
    if [ -f "$SESSION_ENV" ] && run_service_for_40s "$name"; then technical=PASS; fi
    echo "$name technical result: $technical"
    rate_case "$name" || return 1
}

run_nested() {
    local name=$1 backend=$2 compat=$3 display=$4 i=0 technical=FAIL
    echo "Starting $name in the current desktop..."
    sudo systemctl stop nucore.service 2>/dev/null || true
    configure "$backend" "$compat" "$display"
    rm -f "$SESSION_ENV" /run/user/$(id -u)/nucore-portable/environment.* 2>/dev/null || true
    "$ROOT/bin/nucore-session.sh" --desktop-host >"$RUN_DIR/$name.backend.log" 2>&1 &
    NESTED_PID=$!
    while [ "$i" -lt 300 ] && [ ! -f "$SESSION_ENV" ] && kill -0 "$NESTED_PID" 2>/dev/null; do
        i=$((i + 1)); sleep 0.1
    done
    if [ -f "$SESSION_ENV" ] && run_service_for_40s "$name"; then technical=PASS; fi
    rm -f "$SESSION_ENV" 2>/dev/null || true
    kill "$NESTED_PID" 2>/dev/null || true
    wait "$NESTED_PID" 2>/dev/null || true
    NESTED_PID=""
    echo "$name technical result: $technical"
    rate_case "$name" || return 1
}

prepare_gdm() {
    [ -n "$GDM_CONF" ] || return 1
    sudo sed -i -E \
        -e 's/^[#[:space:]]*AutomaticLoginEnable[[:space:]]*=.*/AutomaticLoginEnable = true/' \
        -e "s/^[#[:space:]]*AutomaticLogin[[:space:]]*=.*/AutomaticLogin = $(id -un)/" "$GDM_CONF"
    sudo systemctl start display-manager.service
    local i=0 env
    while [ "$i" -lt 600 ]; do
        env=$(systemctl --user show-environment 2>/dev/null || true)
        grep -qE '^(WAYLAND_DISPLAY|DISPLAY)=' <<<"$env" && return 0
        i=$((i + 1)); sleep 0.1
    done
    return 1
}

run_dm() {
    local name=$1 compat=$2 display=$3 technical=FAIL
    echo "Starting $name..."
    configure display-manager "$compat" "$display"
    if run_service_for_40s "$name"; then technical=PASS; fi
    echo "$name technical result: $technical"
    rate_case "$name" || return 1
}

desktop_ready() {
    local env
    env=$(systemctl --user show-environment 2>/dev/null || true)
    grep -qE '^(WAYLAND_DISPLAY|DISPLAY)=' <<<"$env"
}

if [ "$DESKTOP" -eq 1 ]; then
    desktop_ready || { echo "test-matrix.sh: no live desktop display in systemd --user" >&2; exit 2; }
    [ -n "$ONLY" ] || echo "Desktop mode omits Xorg and direct-console cases; use the normal matrix for those."
    selected gamescope-sdl1 && run_nested gamescope-sdl1 gamescope 0 auto
    selected gamescope-sdl2-wayland && run_nested gamescope-sdl2-wayland gamescope 1 wayland
    selected gamescope-sdl2-xwayland && run_nested gamescope-sdl2-xwayland gamescope 1 xwayland
    selected cage-sdl2-wayland && run_nested cage-sdl2-wayland cage 1 wayland
    selected weston-sdl1 && run_nested weston-sdl1 weston 0 auto
    selected weston-sdl2-wayland && run_nested weston-sdl2-wayland weston 1 wayland
    selected weston-sdl2-xwayland && run_nested weston-sdl2-xwayland weston 1 xwayland
else
    selected gamescope-sdl1 && run_standalone gamescope-sdl1 gamescope 0 auto
    selected gamescope-sdl2-wayland && run_standalone gamescope-sdl2-wayland gamescope 1 wayland
    selected gamescope-sdl2-xwayland && run_standalone gamescope-sdl2-xwayland gamescope 1 xwayland
    selected cage-sdl2-wayland && run_standalone cage-sdl2-wayland cage 1 wayland
    selected weston-sdl1 && run_standalone weston-sdl1 weston 0 auto
    selected weston-sdl2-wayland && run_standalone weston-sdl2-wayland weston 1 wayland
    selected weston-sdl2-xwayland && run_standalone weston-sdl2-xwayland weston 1 xwayland
    selected xorg-sdl1 && run_standalone xorg-sdl1 xorg 0 auto
    selected xorg-sdl2 && run_standalone xorg-sdl2 xorg 1 auto
    selected console-sdl1 && run_standalone console-sdl1 console 0 auto
    selected kmsdrm-sdl2 && run_standalone kmsdrm-sdl2 kmsdrm 1 kmsdrm
fi

if selected display-manager-sdl1 ||
   selected display-manager-sdl2-wayland ||
   selected display-manager-sdl2-xwayland; then
    if [ "$DESKTOP" -eq 1 ] || prepare_gdm; then
        selected display-manager-sdl1 && run_dm display-manager-sdl1 0 auto
        selected display-manager-sdl2-wayland && run_dm display-manager-sdl2-wayland 1 wayland
        selected display-manager-sdl2-xwayland && run_dm display-manager-sdl2-xwayland 1 xwayland
    else
        echo "Display-manager cases skipped: a GDM user session was not available."
    fi
fi

echo
echo "Matrix finished:"
cat "$RESULTS"
