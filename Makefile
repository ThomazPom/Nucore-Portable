# Top-level convenience Makefile. The actual rules live in src/Makefile;
# this just delegates so you can run `make` from the bundle root.
#
#   make          # builds bin/sigio_fix.so (the LD_PRELOAD audio/signal shim)
#   make clean    # removes built artefacts
#
# See src/sigio_fix.c and the README section "sigio_fix.so — what it is"
# for the full story on why this shim is mandatory on x86_64 hosts.

.PHONY: all clean
all clean:
	$(MAKE) -C src $@
