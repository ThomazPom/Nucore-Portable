# Build the two small LD_PRELOAD adapters maintained by Nucore Portable:
# sigio_fix.so for the legacy signal/audio path, and sdl12_wayland_fix.so for
# SDL12-compat's native-Wayland presentation path.
#
# Usage:
#   make            # builds both adapters in ../bin/
#   make clean
#
# Requirements (Debian/Ubuntu):
#   sudo dpkg --add-architecture i386
#   sudo apt update
#   sudo apt install gcc-multilib libc6-dev-i386
# (Fedora: glibc-devel.i686 ; Arch: lib32-glibc + multilib gcc.)
#
# The shipped binaries were built with this Makefile; rebuild only after
# changing their corresponding source.

CC      ?= gcc
CFLAGS  ?= -m32 -shared -fPIC -O1 -Wall
LDLIBS  ?= -ldl -lpthread

SIGIO_OUT         := ../bin/sigio_fix.so
SDL12_WAYLAND_OUT := ../bin/sdl12_wayland_fix.so

.PHONY: all clean
all: $(SIGIO_OUT) $(SDL12_WAYLAND_OUT)

$(SIGIO_OUT): sigio_fix.c
	$(CC) $(CFLAGS) -o $@ $< $(LDLIBS)

$(SDL12_WAYLAND_OUT): sdl12_wayland_fix.c
	$(CC) -m32 -shared -fPIC -nostdlib -o $@ $<

clean:
	rm -f $(SIGIO_OUT) $(SDL12_WAYLAND_OUT)
