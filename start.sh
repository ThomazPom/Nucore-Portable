#!/bin/bash
# start.sh — quick test launcher for nucore-portable.
#
# Usage: ./start.sh [--no-reboot] [--pinbox] [--asix] [--] [game] [extra args...]
#
# Production targets (default):
#   runner = run        (auto-restarts the emulator on crash)
#   binary = nucore     (Nucore 2.25.3R, full watchdog, hard reboot on stall)
#
# Modifiers:
#   --no-reboot   use the dying-process variants (runrd + nucore_nwd / pinbox_nwd).
#                 Crashes exit cleanly instead of triggering a host reboot —
#                 use this for development / patching outside a real cabinet.
#   --pinbox      target the pinbox fork instead of nucore.
#                 Combined matrix:
#                     (default)               run        + nucore
#                     --no-reboot             runrd      + nucore_nwd
#                     --pinbox                run        + pinbox
#                     --pinbox --no-reboot    run_pb_rd  + pinbox_nwd
#   --asix        load the ASIX libftchipid overlay (USB-to-serial cabinet I/O).
#
# game = swe1_14 (default) | rfm_15 | auto
#   swe1_14   Star Wars Episode 1 - Revision 1.4
#   rfm_15    Revenge From Mars   - Revision 1.5
#   auto      auto-detect game
# (Short aliases swe1 / rfm are accepted and mapped to swe1_14 / rfm_15.)
# Extra args are passed through to the emulator (e.g. -fullscreen -bpp 16,
# -window, -parallel 0x378, -nojukeplay, etc.).
#
# Examples:
#   ./start.sh                                 # production: run + nucore + swe1_14 fullscreen
#   ./start.sh --no-reboot rfm_15              # safe testing: runrd + nucore_nwd + rfm_15
#   ./start.sh --pinbox swe1_14                # production pinbox fork on swe1_14
#   ./start.sh --pinbox --no-reboot rfm_15     # safe testing of pinbox on rfm_15
#   ./start.sh --asix swe1_14 -parallel 0x378  # production with ASIX + LPT cabinet I/O
#
# Privilege escalation:
#   nucore needs CAP_SYS_RAWIO (parallel-port ioperm) and CAP_SYS_NICE
#   (real-time audio scheduling). start.sh tries, in order:
#     1. nothing — if already launched with the right caps (e.g. from the
#        systemd kiosk unit installed by install.sh, which uses
#        AmbientCapabilities), no escalation is performed.
#     2. run0   — modern, polkit-based (systemd >=256 / Debian 13 trixie).
#                 Pops a proper GUI auth dialog. Default on stock Debian 13
#                 where the user is not in the sudoers file.
#     3. pkexec — polkit fallback (older systems with policykit-1).
#     4. sudo   — classic; works if the user is in the sudoers file.
#   In all three cases we explicitly forward DISPLAY / XAUTHORITY /
#   WAYLAND_DISPLAY / XDG_RUNTIME_DIR / HOME across the privilege boundary
#   (run0 --setenv=, sudo --preserve-env=, pkexec env VAR=val ...) so SDL
#   keeps talking to your existing X/Wayland session and doesn't fall back
#   to direct framebuffer rendering (which would freeze the compositor).
#   Force a specific path with --root=run0|pkexec|sudo|none, or --no-root
#   to refuse escalation entirely.
#
# Idle / lock suppression:
#   The launch is wrapped in `systemd-inhibit` so the surrounding GNOME/KDE
#   desktop will not auto-idle, lock, sleep or honour the lid switch while
#   nucore is running. The inhibitor lock is registered against THIS shell's
#   logind session (i.e. the user's graphical session), so it works even
#   when run0/pkexec puts nucore itself in a different session view.
#   Disable with --no-inhibit.

set -e

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$SCRIPT_DIR"

NO_REBOOT=0
PINBOX=0
MODE=portable
ROOT_PREF=auto
USE_INHIBIT=1

while [ $# -gt 0 ]; do
    case "$1" in
        --no-reboot)   NO_REBOOT=1;   shift ;;
        --pinbox)      PINBOX=1;      shift ;;
        --asix)        MODE=asix;     shift ;;
        --no-root)     ROOT_PREF=none; shift ;;
        --root)        ROOT_PREF="$2"; shift 2 ;;
        --root=*)      ROOT_PREF="${1#--root=}"; shift ;;
        --no-inhibit)  USE_INHIBIT=0; shift ;;
        --)            shift; break ;;
        -h|--help)
            sed -n '2,60p' "$0"; exit 0 ;;
        --*)
            echo "start.sh: unknown option '$1'" >&2; exit 2 ;;
        *)             break ;;
    esac
done

# Pick runner + binary from the (PINBOX, NO_REBOOT) matrix.
if [ $PINBOX -eq 1 ] && [ $NO_REBOOT -eq 1 ]; then
    RUNNER=run_pb_rd; BINARY=pinbox_nwd
elif [ $PINBOX -eq 1 ]; then
    RUNNER=run;       BINARY=pinbox
elif [ $NO_REBOOT -eq 1 ]; then
    RUNNER=runrd;     BINARY=nucore_nwd
else
    RUNNER=run;       BINARY=nucore
fi

# Sanity-check the chosen pair exists.
for f in "$RUNNER" "$BINARY"; do
    if [ ! -x "$SCRIPT_DIR/bin/$f" ]; then
        echo "start.sh: missing bin/$f for selected mode" >&2
        exit 3
    fi
done

# pinbox reads its sound bank from roms/<game>_pinbox.bin, but the bundle
# only ships roms/<game>_nucore.bin. Mirror them on first use so pinbox
# can boot without manual file shuffling. Cheap no-op on subsequent runs.
for src in "$SCRIPT_DIR"/roms/*_nucore.bin; do
    [ -f "$src" ] || continue
    dst="${src%_nucore.bin}_pinbox.bin"
    [ -e "$dst" ] || cp -p -- "$src" "$dst"
done

# Game + extra args.
GAME=swe1_14
case "$1" in
    swe1_14|rfm_15|auto) GAME="$1"; shift ;;
    swe1)                GAME=swe1_14; shift ;;   # friendly alias
    rfm)                 GAME=rfm_15;  shift ;;   # friendly alias
    "")                  ;;
    -*)                  ;;          # first arg is a flag for the emulator, keep default game
    *)
        echo "start.sh: unknown game '$1' (expected swe1_14, rfm_15, or auto)" >&2
        exit 2 ;;
esac

ARGS=("$@")
[ ${#ARGS[@]} -eq 0 ] && ARGS=(-fullscreen -bpp 16)

echo "+ mode=$MODE  runner=$RUNNER  binary=$BINARY  game=$GAME  args=${ARGS[*]}"

# ── escalate via sudo (single, simple path) ─────────────────────────────────
# Already root? Or already have CAP_SYS_RAWIO in our effective set
# (e.g. systemd unit with AmbientCapabilities)? Then run direct.
have_caps() {
    [ "$EUID" -eq 0 ] && return 0
    if command -v capsh >/dev/null 2>&1; then
        capsh --has-p=cap_sys_rawio 2>/dev/null && return 0
        return 1
    fi
    # Fallback: decode CapEff hex bitmap from /proc/self/status; bit 17 = CAP_SYS_RAWIO.
    local hex
    hex=$(awk '/^CapEff:/ {print $2}' /proc/self/status 2>/dev/null) || return 1
    [ -n "$hex" ] || return 1
    [ $(( 0x$hex >> 17 & 1 )) -eq 1 ]
}

CMD=("$SCRIPT_DIR/bin/bundled.sh" "$MODE" \
     "$SCRIPT_DIR/bin/$RUNNER" \
     "$SCRIPT_DIR/bin/$BINARY" \
     "$GAME" "${ARGS[@]}")

# Wrap with systemd-inhibit so the surrounding GNOME/KDE session does not
# auto-idle, lock, sleep or honour the lid switch while nucore is running.
# The inhibitor lock is registered against THIS shell's logind session
# (i.e. the user's graphical session), so it works even if escalation
# (run0/pkexec) puts nucore itself in a different session view.
if [ "$USE_INHIBIT" -eq 1 ] && command -v systemd-inhibit >/dev/null 2>&1; then
    INHIBIT=(systemd-inhibit \
        --what=idle:sleep:handle-lid-switch:handle-power-key:handle-suspend-key \
        --who="nucore-portable" \
        --why="Pinball 2000 emulator running" \
        --mode=block)
    echo "+ idle/lock inhibitor: held until nucore exits"
else
    INHIBIT=()
fi

if have_caps; then
    echo "+ already have CAP_SYS_RAWIO (or root) — no escalation"
    exec "${INHIBIT[@]}" "${CMD[@]}"
fi

# ── escalation strategy ────────────────────────────────────────────────────
# Pick a tool to elevate to root, and pass through the env that SDL needs
# to talk to the running display server. Without DISPLAY/XAUTHORITY (X) or
# WAYLAND_DISPLAY/XDG_RUNTIME_DIR (Wayland), nucore's SDL falls back to
# direct framebuffer rendering and fights the compositor — that's the
# 1:1-top-left + GNOME freeze you saw earlier with vanilla run0/pkexec.
#
# All three escalators below preserve those vars explicitly:
#   • run0   --setenv=VAR              (inherit value from caller)
#   • sudo   --preserve-env=VAR,...    (whitelist)
#   • pkexec env VAR=val ... cmd       (pkexec strips env, so we re-set it
#                                       inside the elevated shell)
# Root can read the user's $XAUTHORITY cookie file directly (root reads
# anything), so the X auth handshake just works.
PRESERVE_VARS=(DISPLAY XAUTHORITY WAYLAND_DISPLAY XDG_RUNTIME_DIR HOME)

pick_escalator() {
    case "$ROOT_PREF" in
        none)   echo ""; return 0 ;;
        run0|sudo|pkexec)
            command -v "$ROOT_PREF" >/dev/null 2>&1 || {
                echo "start.sh: --root=$ROOT_PREF requested but '$ROOT_PREF' not in PATH" >&2
                exit 4
            }
            echo "$ROOT_PREF"; return 0 ;;
        auto)   ;;
        *)      echo "start.sh: --root must be one of: run0, pkexec, sudo, none" >&2
                exit 2 ;;
    esac
    # run0 first: proper polkit GUI auth, no sudoers required.
    # pkexec next: same auth model on systems without systemd 256.
    # sudo last: works for users in the sudoers file.
    for c in run0 pkexec sudo; do
        command -v "$c" >/dev/null 2>&1 && { echo "$c"; return 0; }
    done
    echo ""
}

ESC=$(pick_escalator)

if [ -z "$ESC" ]; then
    cat >&2 <<EOF
start.sh: cannot escalate privileges and current process lacks CAP_SYS_RAWIO.
nucore needs raw I/O access for the parallel port and real-time scheduling.
Pick one of these:
  • Run the kiosk installer once: sudo ./install.sh
    (sets up a systemd unit with AmbientCapabilities — no escalation tool
     needed at runtime. RECOMMENDED for cabinet kiosk mode.)
  • Install run0 (systemd >=256, default on Debian 13 trixie),
    or install policykit-1 (pkexec), or add yourself to the sudoers file.
  • Force a specific tool: ./start.sh --root=run0|pkexec|sudo
  • Inside the systemd unit only: ./start.sh --no-root
EOF
    exit 5
fi

echo "+ escalating with: $ESC (preserving ${PRESERVE_VARS[*]})"
case "$ESC" in
    run0)
        SETENV=()
        for v in "${PRESERVE_VARS[@]}"; do
            [ -n "${!v+x}" ] && SETENV+=(--setenv="$v")
        done
        exec "${INHIBIT[@]}" run0 --description="nucore-portable" "${SETENV[@]}" -- "${CMD[@]}"
        ;;
    sudo)
        # Build comma-separated whitelist of vars we actually have set.
        keep=""
        for v in "${PRESERVE_VARS[@]}"; do
            [ -n "${!v+x}" ] && keep="${keep:+$keep,}$v"
        done
        if [ -n "$keep" ]; then
            exec "${INHIBIT[@]}" sudo --preserve-env="$keep" "${CMD[@]}"
        else
            exec "${INHIBIT[@]}" sudo "${CMD[@]}"
        fi
        ;;
    pkexec)
        # pkexec strips env unconditionally. Re-inject via `env` inside the
        # elevated shell so SDL still sees DISPLAY etc.
        ENVARGS=()
        for v in "${PRESERVE_VARS[@]}"; do
            [ -n "${!v+x}" ] && ENVARGS+=("$v=${!v}")
        done
        exec "${INHIBIT[@]}" pkexec /usr/bin/env "${ENVARGS[@]}" "${CMD[@]}"
        ;;
esac

echo "+ escalating every launch with: $ESC (no shim available)"
case "$ESC" in
    run0)   exec "${INHIBIT[@]}" run0   --description="nucore-portable" -- "${CMD[@]}" ;;
    pkexec) exec "${INHIBIT[@]}" pkexec "${CMD[@]}" ;;
    sudo)   exec "${INHIBIT[@]}" sudo   "${CMD[@]}" ;;
esac
