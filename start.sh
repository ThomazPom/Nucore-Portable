#!/bin/bash
# start.sh — quick test launcher for nucore-portable.
#
# Usage: ./start.sh [--no-reboot] [--no-runner] [--pinbox] [--asix] [--sdl12-compat]
#                   [--wayland|--xwayland] [--console]
#                   [--no-shim] [--no-audio-shim] [--no-sigio-shim]
#                   [--config FILE]
#                   [--] [game] [extra args...]
#
# Production targets (default):
#   runner = run        (auto-restarts the emulator on crash)
#   binary = nucore     (Nucore 2.25.3R, full watchdog, hard reboot on stall)
#
# Modifiers:
#   --no-reboot   use the dying-process variants (runrd + nucore_nwd / pinbox_nwd).
#                 Crashes exit cleanly instead of triggering a host reboot —
#                 use this for development / patching outside a real cabinet.
#   --no-runner   launch the emulator binary directly through the bundle.
#                 Implies --no-reboot so a failure exits instead of rebooting
#                 the host. Useful for separating emulator and runner behaviour.
#   --pinbox      target the pinbox fork instead of nucore.
#                 Combined matrix:
#                     (default)               run        + nucore
#                     --no-reboot             runrd      + nucore_nwd
#                     --pinbox                run        + pinbox
#                     --pinbox --no-reboot    run_pb_rd  + pinbox_nwd
#   --asix        EXPERIMENTAL: select the newer ASIX libftchipid 0.1.0 path.
#                 It was tested because it uses libstdc++.so.6, available on
#                 modern Debian, instead of Nucore's original libstdc++.so.5.
#   --sdl12-compat
#                 EXPERIMENTAL: translate the SDL 1.2 ABI to bundled SDL 2.
#                 The proven native SDL 1.2 path remains the default.
#   --wayland     with SDL12-compat, use SDL2's native Wayland backend.
#   --xwayland    with SDL12-compat, use SDL2's X11 backend through Xwayland.
#   --console     ADVANCED: allow SDL to use a direct-display backend.
#                 Refuses active graphical sessions, but does not force fbcon:
#                 native SDL may choose fbcon and SDL2 may choose KMSDRM.
#   --no-shim     EXPERIMENTAL: do not preload sigio_fix.so. Safe only for
#                 testing; the real cabinet RTC/SIGIO path is unverified.
#   --no-audio-shim
#                 keep RTC/SIGIO protection but disable its audio interventions.
#                 Audio protection is enabled by default in every SDL mode.
#   --no-sigio-shim
#                 keep audio interventions but disable RTC/SIGIO protection.
#                 Diagnostic only: this may restore the legacy boot/crash bug.
#   --config FILE prepend a saved Nucore-Portable command line. The file may
#                 contain launcher --options, a game and Nucore -options.
#                 This is unrelated to Nucore's automatic config/pb2k.cfg.
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
#   ./start.sh --asix --no-reboot swe1_14      # experimental ASIX libftchipid path
#
# Privilege escalation:
#   nucore needs CAP_SYS_RAWIO (parallel-port ioperm) and CAP_SYS_NICE
#   (real-time audio scheduling). start.sh tries, in order:
#     1. nothing — when already root or launched with the required capability
#        (the installed system service runs as root), no escalation is done.
#     2. run0   — modern, polkit-based (systemd >=256 / Debian 13 trixie).
#                 Pops a proper GUI auth dialog. Default on stock Debian 13
#                 where the user is not in the sudoers file.
#     3. pkexec — polkit fallback (older systems with policykit-1).
#     4. sudo   — classic; works if the user is in the sudoers file.
#   In all three cases we explicitly forward DISPLAY / XAUTHORITY /
#   WAYLAND_DISPLAY / XDG_RUNTIME_DIR / HOME and explicitly supplied SDL
#   video overrides across the privilege boundary
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

# Extract Nucore-Portable's own --config before normal option parsing. Its
# contents are prepended, so explicit command-line words can add to the saved
# command. GNU xargs supplies shell-like quote parsing without eval: command
# substitutions and variables in the file are never executed or expanded.
PORTABLE_CONFIG=""
CLI_WORDS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --config)
            [ "$#" -ge 2 ] || { echo "start.sh: --config requires a file" >&2; exit 2; }
            PORTABLE_CONFIG="$2"; shift 2 ;;
        --config=)
            echo "start.sh: --config requires a file" >&2; exit 2 ;;
        --config=*)
            PORTABLE_CONFIG="${1#--config=}"; shift ;;
        --)
            CLI_WORDS+=("$@"); break ;;
        --*)
            CLI_WORDS+=("$1"); shift ;;
        *)
            CLI_WORDS+=("$@"); break ;;
    esac
done

CONFIG_WORDS=()
if [ -n "$PORTABLE_CONFIG" ]; then
    case "$PORTABLE_CONFIG" in
        /*) ;;
        *) PORTABLE_CONFIG="$SCRIPT_DIR/$PORTABLE_CONFIG" ;;
    esac
    PORTABLE_CONFIG=$(readlink -f -- "$PORTABLE_CONFIG") || {
        echo "start.sh: portable config does not exist" >&2; exit 2;
    }
    [ -f "$PORTABLE_CONFIG" ] || {
        echo "start.sh: portable config is not a regular file: $PORTABLE_CONFIG" >&2; exit 2;
    }
    CONFIG_TEXT=$(sed '/^[[:space:]]*#/d; /^[[:space:]]*$/d' "$PORTABLE_CONFIG")
    if [ -n "$CONFIG_TEXT" ]; then
        CONFIG_TEXT=$(printf '%s\n' "$CONFIG_TEXT" | xargs -n1 printf '%s\n') || {
            echo "start.sh: cannot parse portable config: $PORTABLE_CONFIG" >&2; exit 2;
        }
        mapfile -t CONFIG_WORDS <<< "$CONFIG_TEXT"
    fi
fi
set -- "${CONFIG_WORDS[@]}" "${CLI_WORDS[@]}"

NO_REBOOT=0
NO_RUNNER=0
PINBOX=0
ASIX=0
SDL12_COMPAT=0
SDL_DISPLAY=auto
ALLOW_CONSOLE=0
USE_SHIM=1
SHIM_AUDIO=1
SHIM_SIGIO=1
ROOT_PREF=auto
USE_INHIBIT=1

while [ $# -gt 0 ]; do
    case "$1" in
        --no-reboot)   NO_REBOOT=1;   shift ;;
        --no-runner)   NO_RUNNER=1; NO_REBOOT=1; shift ;;
        --pinbox)      PINBOX=1;      shift ;;
        --asix)        ASIX=1;        shift ;;
        --sdl12-compat) SDL12_COMPAT=1; shift ;;
        --wayland)     SDL_DISPLAY=wayland; shift ;;
        --xwayland)    SDL_DISPLAY=xwayland; shift ;;
        --console)     ALLOW_CONSOLE=1; shift ;;
        --no-shim)     USE_SHIM=0;    shift ;;
        --no-audio-shim) SHIM_AUDIO=0; shift ;;
        --no-sigio-shim) SHIM_SIGIO=0; shift ;;
        --no-root)     ROOT_PREF=none; shift ;;
        --root)
            [ "$#" -ge 2 ] || { echo "start.sh: --root requires a value" >&2; exit 2; }
            ROOT_PREF="$2"; shift 2 ;;
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

if [ "$SDL_DISPLAY" != auto ] && [ "$SDL12_COMPAT" -ne 1 ]; then
    echo "start.sh: --$SDL_DISPLAY requires --sdl12-compat" >&2
    exit 2
fi

# These overlays are orthogonal. Native SDL 1.2 remains the default and the
# compatibility library is selected only when explicitly requested.
if [ "$SDL12_COMPAT" -eq 1 ] && [ "$ASIX" -eq 1 ]; then
    MODE=sdl12-compat-asix
elif [ "$SDL12_COMPAT" -eq 1 ]; then
    MODE=sdl12-compat
elif [ "$ASIX" -eq 1 ]; then
    MODE=asix
else
    MODE=portable
fi

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

# Sanity-check everything that will actually execute.
CHECK_FILES=("$BINARY")
[ "$NO_RUNNER" -eq 1 ] || CHECK_FILES+=("$RUNNER")
for f in "${CHECK_FILES[@]}"; do
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

# Nucore automatically reads ../config/pb2k.cfg from its bin/ working
# directory. Portable enforces only the project-wide no-watermark policy;
# explicit user arguments remain cumulative and follow it.
ARGS=(-nowatermark "$@")

RUNNER_LABEL=$RUNNER
[ "$NO_RUNNER" -eq 1 ] && RUNNER_LABEL=none
echo "+ mode=$MODE  display=$SDL_DISPLAY  runner=$RUNNER_LABEL  binary=$BINARY  game=$GAME  portable_config=${PORTABLE_CONFIG:-none}  args=${ARGS[*]}"

# ── escalate via sudo (single, simple path) ─────────────────────────────────
# Already root, or already have CAP_SYS_RAWIO in our effective set? Run direct.
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

BUNDLE_OPTIONS=()
[ "$NO_RUNNER" -eq 1 ] && BUNDLE_OPTIONS+=(--no-runner)
[ "$SDL_DISPLAY" = wayland ] && BUNDLE_OPTIONS+=(--wayland)
[ "$SDL_DISPLAY" = xwayland ] && BUNDLE_OPTIONS+=(--xwayland)
[ "$ALLOW_CONSOLE" -eq 1 ] && BUNDLE_OPTIONS+=(--console)
[ "$USE_SHIM" -eq 0 ] && BUNDLE_OPTIONS+=(--no-shim)
[ "$SHIM_AUDIO" = 0 ] && BUNDLE_OPTIONS+=(--no-audio-shim)
[ "$SHIM_SIGIO" = 0 ] && BUNDLE_OPTIONS+=(--no-sigio-shim)

CMD=("$SCRIPT_DIR/bin/bundled.sh" "${BUNDLE_OPTIONS[@]}" "$MODE" \
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
#   • run0   env VAR=value ...         (applied after its PAM session)
#   • sudo   --preserve-env=VAR,...    (whitelist)
#   • pkexec env VAR=val ... cmd       (pkexec strips env, so we re-set it
#                                       inside the elevated shell)
# Root can read the user's $XAUTHORITY cookie file directly (root reads
# anything), so the X auth handshake just works.
PRESERVE_VARS=(DISPLAY XAUTHORITY WAYLAND_DISPLAY XDG_RUNTIME_DIR HOME \
               SDL_VIDEODRIVER SDL_RENDER_DRIVER \
               SDL_VIDEO_WAYLAND_ALLOW_LIBDECOR)

pick_escalator() {
    escalator_available() {
        case "$1" in
            run0)
                # Debian ships run0 with systemd but only Suggests polkitd.
                # A stripped installation can therefore have run0 without the
                # pkttyagent needed for interactive authentication.
                command -v run0 >/dev/null 2>&1 &&
                    command -v pkttyagent >/dev/null 2>&1
                ;;
            sudo|pkexec) command -v "$1" >/dev/null 2>&1 ;;
            *) return 1 ;;
        esac
    }
    case "$ROOT_PREF" in
        none)   echo ""; return 0 ;;
        run0|sudo|pkexec)
            escalator_available "$ROOT_PREF" || {
                if [ "$ROOT_PREF" = run0 ] && command -v run0 >/dev/null 2>&1; then
                    echo "start.sh: --root=run0 needs pkttyagent (Debian package: polkitd)" >&2
                else
                    echo "start.sh: --root=$ROOT_PREF is unavailable" >&2
                fi
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
        escalator_available "$c" && { echo "$c"; return 0; }
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
    (sets up a root system service — no escalation tool is needed at runtime.
     RECOMMENDED for cabinet mode.)
  • Install polkitd for Debian 13's run0 authentication,
    install pkexec, or add yourself to the sudoers file.
  • Force a specific tool: ./start.sh --root=run0|pkexec|sudo
  • Inside the systemd unit only: ./start.sh --no-root
EOF
    exit 5
fi

echo "+ escalating with: $ESC (preserving ${PRESERVE_VARS[*]})"
case "$ESC" in
    run0)
        ENVARGS=()
        for v in "${PRESERVE_VARS[@]}"; do
            [ -n "${!v+x}" ] && ENVARGS+=("$v=${!v}")
        done
        exec "${INHIBIT[@]}" run0 --description="nucore-portable" -- \
            /usr/bin/env "${ENVARGS[@]}" "${CMD[@]}"
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
