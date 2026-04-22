# Build the LD_PRELOAD shim that makes the legacy 32-bit nucore/pinbox
# binaries run cleanly on modern x86_64 Linux. See sigio_fix.c for the
# full theory; in one sentence: it stops the RTC/SIGIO storm from
# corrupting signal-handler stacks and starving the SDL_mixer audio
# callback, both of which would otherwise crash the emulator within
# seconds on any post-2010 kernel + glibc.
#
# Usage:
#   make            # builds ../bin/sigio_fix.so
#   make clean
#
# Requirements (Debian/Ubuntu):
#   sudo dpkg --add-architecture i386
#   sudo apt update
#   sudo apt install gcc-multilib libc6-dev-i386
# (Fedora: glibc-devel.i686 ; Arch: lib32-glibc + multilib gcc.)
#
# The shipped ../bin/sigio_fix.so was built with this Makefile; rebuild
# only if you modify sigio_fix.c.

CC      ?= gcc
CFLAGS  ?= -m32 -shared -fPIC -O1 -Wall
LDLIBS  ?= -ldl -lpthread

OUT     := ../bin/sigio_fix.so
SRC     := sigio_fix.c

.PHONY: all clean
all: $(OUT)

$(OUT): $(SRC)
	$(CC) $(CFLAGS) -o $@ $< $(LDLIBS)

clean:
	rm -f $(OUT)
