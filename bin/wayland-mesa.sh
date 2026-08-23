#!/bin/bash
# Install/check/remove the optional i386 Mesa runtime used by SDL12-compat's
# hardware-backed native Wayland and KMSDRM renderers.
set -euo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
PACK_DIR="$ROOT/bundlex86/optional/wayland-mesa-i386"
PACK_PARENT=$(dirname -- "$PACK_DIR")
VERSION=3
TAG=wayland-mesa-i386-v3
ASSET=nucore-wayland-mesa-i386-v3.tar.xz
SHA256=c9aded5aa4c54098cdd0d00767d136ba48b5a6bf6ef385bc984b3b9f8a27cd80
URL=${NUCORE_WAYLAND_MESA_URL:-https://github.com/ThomazPom/Nucore-Portable/releases/download/$TAG/$ASSET}

valid_pack() {
    [ -f "$PACK_DIR/indirect/libEGL_mesa.so.0" ] &&
    [ -f "$PACK_DIR/indirect/libGLESv2.so.2" ] &&
    [ -f "$PACK_DIR/indirect/libGL.so.1" ] &&
    [ -f "$PACK_DIR/indirect/libGLX.so.0" ] &&
    [ -f "$PACK_DIR/indirect/libudev.so.1" ] &&
    [ -f "$PACK_DIR/egl_vendor.d/50_mesa.json" ] &&
    [ -f "$PACK_DIR/indirect/libSDL2-2.0.so.0" ] &&
    [ -f "$PACK_DIR/dri/mesa_dri_drivers.so" ] &&
    [ -L "$PACK_DIR/dri/iris_dri.so" ] &&
    [ "$(cat "$PACK_DIR/.archive-sha256" 2>/dev/null || true)" = "$SHA256" ]
}

download() {
    local destination=$1
    if command -v curl >/dev/null 2>&1; then
        curl --fail --location --proto '=https' --tlsv1.2 \
            --retry 3 --output "$destination" "$URL"
    elif command -v wget >/dev/null 2>&1; then
        wget --https-only --tries=3 --output-document="$destination" "$URL"
    else
        echo "wayland-mesa.sh: curl or wget is required" >&2
        exit 3
    fi
}

install_pack() {
    local work archive extract candidate backup=""
    if valid_pack; then
        echo "Optional SDL2 graphics/Mesa i386 pack v$VERSION is already installed."
        return 0
    fi
    command -v sha256sum >/dev/null 2>&1 || {
        echo "wayland-mesa.sh: sha256sum is required" >&2; exit 3;
    }
    command -v tar >/dev/null 2>&1 || {
        echo "wayland-mesa.sh: tar is required" >&2; exit 3;
    }
    command -v xz >/dev/null 2>&1 || {
        echo "wayland-mesa.sh: xz is required" >&2; exit 3;
    }
    work=$(mktemp -d /tmp/nucore-wayland-mesa.XXXXXX)
    trap 'rm -rf -- "${work:-}"' EXIT HUP INT TERM
    archive="$work/$ASSET"
    extract="$work/extract"
    mkdir -p "$extract"
    echo "Downloading optional SDL2 graphics/Mesa i386 pack v$VERSION (about 50 MiB)..."
    download "$archive"
    printf '%s  %s\n' "$SHA256" "$archive" | sha256sum --check --status || {
        echo "wayland-mesa.sh: downloaded archive failed SHA-256 verification" >&2
        exit 4
    }
    tar -tJf "$archive" | grep -Eq '(^|/)\.\.?(/|$)|^/' && {
        echo "wayland-mesa.sh: archive contains an unsafe path" >&2; exit 4;
    }
    tar -xJf "$archive" -C "$extract"
    candidate="$extract/wayland-mesa-i386"
    [ -f "$candidate/indirect/libEGL_mesa.so.0" ] &&
    [ -f "$candidate/indirect/libGLESv2.so.2" ] &&
    [ -f "$candidate/indirect/libGL.so.1" ] &&
    [ -f "$candidate/indirect/libGLX.so.0" ] &&
    [ -f "$candidate/indirect/libudev.so.1" ] &&
    [ -f "$candidate/egl_vendor.d/50_mesa.json" ] &&
    [ -f "$candidate/indirect/libSDL2-2.0.so.0" ] &&
    [ -f "$candidate/dri/mesa_dri_drivers.so" ] || {
        echo "wayland-mesa.sh: archive is incomplete" >&2; exit 4;
    }
    printf '%s\n' "$SHA256" >"$candidate/.archive-sha256"
    mkdir -p "$PACK_PARENT"
    if [ -e "$PACK_DIR" ]; then
        backup="$PACK_PARENT/.wayland-mesa-i386.previous.$$"
        mv "$PACK_DIR" "$backup"
    fi
    if mv "$candidate" "$PACK_DIR"; then
        [ -z "$backup" ] || rm -rf -- "$backup"
    else
        [ -z "$backup" ] || mv "$backup" "$PACK_DIR"
        exit 4
    fi
    trap - EXIT HUP INT TERM
    rm -rf -- "$work"
    echo "Installed optional SDL2 graphics/Mesa i386 pack v$VERSION."
}

case "${1:-status}" in
    install) install_pack ;;
    check) valid_pack || exit 1 ;;
    status)
        if valid_pack; then
            echo "installed: SDL2 graphics/Mesa i386 pack v$VERSION"
        else
            echo "not installed: SDL2 graphics/Mesa i386 pack v$VERSION"
            exit 1
        fi
        ;;
    remove)
        case "$PACK_DIR" in "$ROOT"/bundlex86/optional/wayland-mesa-i386) ;; *) exit 4 ;; esac
        rm -rf -- "$PACK_DIR"
        rmdir "$PACK_PARENT" 2>/dev/null || true
        echo "Removed optional SDL2 graphics/Mesa i386 pack."
        ;;
    *) echo "Usage: $0 [install|check|status|remove]" >&2; exit 2 ;;
esac
