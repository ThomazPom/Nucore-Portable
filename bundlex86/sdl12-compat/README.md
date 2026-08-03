# sdl12-compat experimental overlay

This directory contains Debian 13 (trixie)'s i386 build of
`libsdl1.2debian` 1.2.68-3. It implements the SDL 1.2 ABI on top of SDL 2.

- Upstream: https://github.com/libsdl-org/sdl12-compat
- Debian source: `sdl12-compat` 1.2.68-3
- Debian binary: `libsdl1.2debian_1.2.68-3_i386.deb`
- Package SHA-256:
  `46d211507d1e9c1db6879bfcf5c17f927110496c00ac1ad6872f571638fe654e`
- License and copyright notices: see the adjacent `COPYRIGHT` file copied
  verbatim from the Debian binary package.

It is selected only by `./start.sh --sdl12-compat`. The native SDL 1.2
library in `bundlex86/direct` remains the default.
