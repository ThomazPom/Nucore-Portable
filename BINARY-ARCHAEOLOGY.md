# Nucore binary archaeology

Nucore is a proprietary, stripped, 32-bit x86 executable. Its original source
and debugging symbols are not part of this repository. That prevents
source-level debugging, but it does not make the program opaque: its process
arguments, embedded text, dynamic-library calls and observable behaviour can
still answer narrowly framed questions.

This note records the techniques used to investigate Nucore-Portable. It is a
debugging guide, not a claim that the original program has been reconstructed.

## Start with a precise question

Prefer a question with an externally observable answer:

- Did the launcher pass `-window` to the final Nucore process?
- Which SDL implementation was loaded?
- Which flags did Nucore give to `SDL_SetVideoMode`?
- Did it open `../config/pb2k.cfg`?
- Which SONAME does a bundled library require?

This is much more reliable than trying to describe all of a stripped program
at once.

## Follow arguments through the launcher chain

The normal chain is:

```text
start.sh
  -> bundled.sh
       -> run
            -> bundled.sh (wrap mode)
                 -> nucore
```

`run` is itself a binary. The second `bundled.sh` invocation is intentional: it
reapplies the bundled loader and optional preload after the runner's `execv()`.

First read the shell boundary:

```sh
rg -n 'CMD=|exec |"\$@"|_BUNDLED_BINARY' start.sh bin/bundled.sh
```

Then inspect the live argument vector. `/proc/PID/cmdline` is NUL-separated, so
convert it to one item per line:

```sh
pgrep -af 'bin/(run|nucore)|ld-linux.so.2'
tr '\0' '\n' </proc/PID/cmdline
```

For the reported `./start.sh -window` case, the live final process contained:

```text
.../bin/nucore
swe1_14
-nowatermark
-window
```

That proves the portable launcher and runner did not lose `-window`. It does
not, by itself, prove what Nucore subsequently does with the option.

## Recover the program's own vocabulary

Even a stripped executable commonly retains user-facing strings, configuration
keys, library names and error messages:

```sh
file bin/nucore bin/run
strings -a -t x bin/nucore | less
strings -a bin/nucore | rg -i 'window|fullscreen|watermark|usage|help'
strings -a bin/nucore | rg 'FULL_SCREEN|BPP|WATERMARK'
```

Finding both `window` and `fullscreen` establishes that these words exist in
the binary. References in disassembly can then show whether they belong to an
option table, but a string alone never proves that an option works correctly.

Useful static tools include:

```sh
readelf -h -d -s bin/nucore
objdump -p bin/nucore
objdump -d -Mintel bin/nucore | less
```

Addresses and offsets are build-specific. Record the binary checksum whenever
publishing a low-level finding:

```sh
sha256sum bin/nucore bin/pinbox bin/run
```

## Observe the SDL boundary with GDB

Although Nucore has no symbols, bundled SDL exports dynamic symbols. GDB can
therefore stop at `SDL_SetVideoMode`, a boundary where Nucore's decision has
already become concrete.

Run from `bin/` so Nucore finds `../config/pb2k.cfg` exactly as it does during a
normal launch:

```sh
cd bin
gdb -q -nx -batch \
  -ex 'set breakpoint pending on' \
  -ex 'break SDL_SetVideoMode' \
  -ex run \
  -ex 'bt 1' \
  -ex 'printf "width=%d height=%d bpp=%d flags=0x%x\n", *(int*)($esp+4), *(int*)($esp+8), *(int*)($esp+12), *(unsigned int*)($esp+16)' \
  --args ../bundlex86/indirect/ld-linux.so.2 \
    --inhibit-cache \
    --library-path ../bundlex86/direct:../bundlex86/indirect \
    ./nucore_nwd swe1_14 -fullscreen
```

This stack expression is specific to 32-bit x86's cdecl calling convention:
the return address is at `$esp`, followed by width, height, bits per pixel and
flags. For the bundled build, a fullscreen test produced:

```text
width=640 height=480 bpp=16 flags=0xe0000101
```

The `SDL_FULLSCREEN` bit is `0x80000000`. Compare otherwise identical runs and
look for that bit; do not infer display mode merely from whether a window is
visually visible.

If GDB reports a segmentation fault before the SDL breakpoint, the printed
stack words are meaningless. Confirm that the backtrace actually says
`SDL_SetVideoMode` before interpreting them.

## Observe files and libraries

To verify configuration access rather than guessing from behaviour:

```sh
strace -f -e trace=openat,read,statx \
  ./start.sh --no-reboot swe1_14 -window 2>&1 |
  rg 'pb2k\.cfg|ENOENT'
```

To see which shared objects the loader selects:

```sh
LD_DEBUG=libs ./start.sh --no-reboot swe1_14 -window 2>&1 | less
```

`LD_DEBUG` is noisy. Use it for a short diagnostic launch, not normal cabinet
operation.

## The `-window` finding

The current evidence separates two questions:

1. The live `nucore` process receives `-nowatermark -window`; neither
   `start.sh`, `bundled.sh` nor `run` removes it.
2. With `FULL_SCREEN=1`, the observed Nucore launch remains fullscreen. With
   `FULL_SCREEN=0`, the same binary launches windowed. Pinbox behaves
   differently.

This strongly indicates Nucore's own option/configuration handling is decisive.
It does not yet identify the exact internal instruction or prove whether the
cause is configuration load order, an option-parser defect, or another later
assignment. That narrower claim would require clean comparative breakpoints or
disassembly of the relevant write.

Nucore-Portable therefore implements a boundary-layer workaround: an explicit
`-window` or `-fullscreen` updates only `FULL_SCREEN` in `pb2k.cfg` before the
binary starts. With no explicit video-mode argument, the launcher leaves the
file untouched. This does not patch or pretend to repair Nucore's internals;
it makes the existing configuration interface deterministic.

## Keep experiments honest

- Change one input at a time and record the complete command line.
- Use `--no-reboot` for diagnostics.
- Check for an already running Nucore first; its watchdog, shared memory or
  hardware resources can invalidate a second run.
- Do not attach GDB to a live cabinet game unless interruption is acceptable.
- Preserve the user's config and save data. Work on a copy when a test requires
  edits.
- Distinguish proof from inference in notes and commit messages.
- Repeat important tests with native SDL 1.2 and SDL12-compat when the boundary
  being studied could differ between them.

The practical lesson is that a stripped binary can still be debugged well at
its boundaries. The goal is not to guess its source; it is to combine static
clues with process-level measurements until only one layer can explain the
observed result.
