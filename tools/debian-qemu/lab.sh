#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)
LAB_DIR=${NUCORE_QEMU_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/nucore-qemu}
BASE=$LAB_DIR/debian13-minimal.qcow2
OVERLAY=$LAB_DIR/current.qcow2
PIDFILE=$LAB_DIR/qemu.pid
LOG=$LAB_DIR/serial.log
SSH_PORT=${NUCORE_QEMU_SSH_PORT:-22222}
RAM=${NUCORE_QEMU_RAM:-2048}
CPUS=${NUCORE_QEMU_CPUS:-2}
KERNEL_URL=${NUCORE_QEMU_KERNEL_URL:-https://deb.debian.org/debian/dists/trixie/main/installer-amd64/current/images/netboot/debian-installer/amd64/linux}
INITRD_URL=${NUCORE_QEMU_INITRD_URL:-https://deb.debian.org/debian/dists/trixie/main/installer-amd64/current/images/netboot/debian-installer/amd64/initrd.gz}

die() { echo "lab.sh: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing '$1' (on Debian: apt install qemu-system-x86 qemu-utils curl cpio gzip openssh-client)"; }

prereqs() {
    for command in qemu-system-x86_64 qemu-img curl cpio gzip ssh tar; do need "$command"; done
}

running() {
    local pid
    { [ -s "$PIDFILE" ] && read -r pid < "$PIDFILE"; } 2>/dev/null || return 1
    [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null
}

stop_vm() {
    local pid=""
    { [ -s "$PIDFILE" ] && read -r pid < "$PIDFILE"; } 2>/dev/null || true
    if running; then
        kill "$pid" 2>/dev/null || true
        for _ in {1..30}; do running || break; sleep 0.2; done
        running && kill -KILL "$pid" 2>/dev/null || true
    fi
    rm -f "$PIDFILE"
}

wait_ssh() {
    for _ in {1..180}; do
        ssh_guest true >/dev/null 2>&1 && return 0
        running || { tail -80 "$LOG" >&2; die "VM stopped before SSH became ready"; }
        sleep 2
    done
    tail -80 "$LOG" >&2
    die "timed out waiting for guest SSH"
}

ssh_guest() {
    sshpass -p cabinet ssh -p "$SSH_PORT" \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR -o ConnectTimeout=2 root@127.0.0.1 "$@"
}

accel_args() {
    if [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
        printf '%s\n' -enable-kvm -cpu host
    else
        printf '%s\n' -accel tcg -cpu max
    fi
}

start_overlay() {
    [ -f "$OVERLAY" ] || die "no overlay; run '$0 reset' first"
    running && die "VM is already running"
    : > "$LOG"
    mapfile -t accel < <(accel_args)
    qemu-system-x86_64 "${accel[@]}" -machine q35 \
        -m "$RAM" -smp "$CPUS" -drive "file=$OVERLAY,if=virtio,format=qcow2" \
        -nic "user,model=virtio-net-pci,hostfwd=tcp:127.0.0.1:${SSH_PORT}-:22" \
        -display none -serial "file:$LOG" -daemonize -pidfile "$PIDFILE"
    wait_ssh
}

make_initrd() {
    local work=$1
    curl -fL --retry 3 -o "$work/linux" "$KERNEL_URL"
    curl -fL --retry 3 -o "$work/initrd.gz" "$INITRD_URL"
    cp "$work/initrd.gz" "$work/preseed-initrd.gz"
    (
        cd "$SCRIPT_DIR"
        printf '%s\n' preseed.cfg | cpio -o -H newc 2>/dev/null | gzip -c
    ) >> "$work/preseed-initrd.gz"
}

prepare() {
    prereqs
    mkdir -p "$LAB_DIR"
    [ ! -e "$BASE" ] || { echo "Base already exists: $BASE"; return; }
    local work
    work=$(mktemp -d "$LAB_DIR/prepare.XXXXXX")
    make_initrd "$work"
    qemu-img create -f qcow2 "$LAB_DIR/installing.qcow2" 16G
    : > "$LOG"
    echo "Installing stripped Debian 13 base (network speed determines duration)..."
    mapfile -t accel < <(accel_args)
    qemu-system-x86_64 "${accel[@]}" -machine q35 \
        -m "$RAM" -smp "$CPUS" -drive "file=$LAB_DIR/installing.qcow2,if=virtio,format=qcow2" \
        -nic user,model=virtio-net-pci -display none -serial "file:$LOG" \
        -kernel "$work/linux" -initrd "$work/preseed-initrd.gz" \
        -append 'auto=true priority=critical preseed/file=/preseed.cfg interface=auto netcfg/disable_autoconfig=false console=ttyS0,115200n8 --- quiet' \
        -no-reboot
    qemu-img check "$LAB_DIR/installing.qcow2"
    mv "$LAB_DIR/installing.qcow2" "$BASE"
    chmod a-w "$BASE"
    rm -rf -- "$work"
    echo "Sealed base image: $BASE"
}

reset_overlay() {
    prereqs
    stop_vm
    [ -f "$BASE" ] || die "base missing; run '$0 prepare'"
    rm -f "$OVERLAY"
    qemu-img create -f qcow2 -F qcow2 -b "$BASE" "$OVERLAY"
    echo "Fresh overlay: $OVERLAY"
}

copy_checkout() {
    # Preserve the exact worktree under test, excluding Git metadata and game
    # save mutations. Root extracts it, preserving the installer's boundary.
    tar -C "$REPO_ROOT" --exclude=.git --exclude='roms/savedata/*' -cf - . |
        ssh_guest "rm -rf /opt/Nucore-Portable && mkdir -p /opt/Nucore-Portable && tar -C /opt/Nucore-Portable -xf - && chown -R root:root /opt/Nucore-Portable"
}

assert_stripped_guest() {
    ssh_guest 'command -v run0 >/dev/null && ! command -v pkttyagent >/dev/null && ! command -v pkexec >/dev/null && ! command -v sudo >/dev/null'
}

test_install() {
    local backend=${1:-xorg} answers
    case "$backend" in xorg|console|gamescope|cage|weston) ;; *) die "unsupported stripped-guest backend: $backend" ;; esac
    reset_overlay
    start_overlay
    assert_stripped_guest
    copy_checkout
    # User, trust writable checkout (not asked for root-owned /opt), config,
    # game, Pinbox, watchdog, optional SDL/ASIX, fullscreen, bpp, maintenance,
    # quiet boot, zero GRUB, proceed, and any backend package installation.
    case "$backend" in
        console) answers=$'cabinet\n\nswe1_14\nn\ny\nn\ny\n16\ny\ny\ny\n' ;;
        *)       answers=$'cabinet\n\nswe1_14\nn\ny\nn\nn\ny\n32\ny\ny\ny\ny\n' ;;
    esac
    printf '%s' "$answers" | ssh_guest "cd /opt/Nucore-Portable && ./install.sh --$backend"
    ssh_guest "test -s /etc/nucore-portable/session.conf && test -s /etc/nucore-portable/launch.args && systemctl is-enabled --quiet nucore.service && grep -qx BACKEND=$backend /etc/nucore-portable/session.conf"
    ssh_guest "cd /opt/Nucore-Portable && ./uninstall.sh"
    ssh_guest "test ! -e /etc/systemd/system/nucore.service && test ! -e /etc/nucore-portable/session.conf && test ! -e /var/lib/nucore-portable/install-mode"
    stop_vm
    echo "PASS: stripped Debian install/uninstall ($backend)"
}

case "${1:-}" in
    prepare) prepare ;;
    reset) reset_overlay ;;
    boot) start_overlay ;;
    stop) stop_vm ;;
    shell) need sshpass; shift; ssh_guest "$@" ;;
    test) prereqs; need sshpass; test_install "${2:-xorg}" ;;
    all) prepare; test_install xorg ;;
    *) echo "Usage: $0 {all|prepare|reset|boot|shell|stop|test BACKEND}" >&2; exit 2 ;;
esac
