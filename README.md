# nucore-portable

A self-contained, x86_64-friendly bundle of the legacy 32-bit Pinball 2000
emulator (`nucore`) and its `pinbox` fork. Drop it on a stock Debian 13 (or
similar) x64 machine, run `./start.sh`, and you get a working pinball without
ever touching `dpkg --add-architecture i386` or chasing 32-bit `.so` packages.

## Quick start

The whole repo is designed to be a **drop-in cabinet brain replacement**:

```sh
git clone <this-repo> nucore-portable
cd nucore-portable
./start.sh --no-reboot swe1_14 -window  # safe desktop test, no install needed
./start.sh --no-reboot swe1_14 -fullscreen -bpp 16
./install.sh         # turn the box into a Pinball-2000 cabinet:
                     #   • autostarts on graphical login
                     #   • cross-distro display-manager autologin
                     #   • F1/Esc → back to a normal desktop
```

That's the whole user story. Clone anywhere on the disk, run it from
where it lives, no build step, no apt dependencies, no `~/.config`
pollution, no `/usr/local` writes outside the systemd / polkit /
display-manager drop-ins (all of which `./uninstall.sh` reverses
cleanly). The bundle ships with its own i386 loader and shared libs,
so the host never needs `dpkg --add-architecture i386` even once.

The first command runs Star Wars windowed with the watchdog disabled. Plain
`./start.sh` selects the production watchdog, which may hard-reboot a cabinet
PC after a stall; always use `--no-reboot` for desktop experiments.

> ⚠️ **Cabinet status.** This *specific bundle* has not yet been tested
> in a real Pinball 2000 cabinet — only on desktop x86_64 hosts with the
> screen + audio paths exercised, and the LPT / ASIX cabinet-I/O code
> paths inherited unchanged from upstream. The `nucore` binary itself
> (Big Guy's Pinball 2.25.3R, shipped here unmodified) **is** known to
> drive thousands of Pinball 2000 machines successfully in the wild;
> what is unproven here is only this bundle's specific glue (the
> sigio_fix shim, the systemd unit, the autologin/session-binding
> wrapper). Real-cabinet reports very welcome.

## What's inside the bundle

The point of this repo is the **bundle around `nucore`**, not nucore itself:

* a curated set of i386 shared libraries (`bundlex86/`, ~37 MB)
* a bundled `ld-linux.so.2` so the host's loader is never used
* a small launcher (`bin/bundled.sh`) that re-execs the binary through the
  bundled loader with a runtime-injected `sigio_fix.so` by default
* `src/sigio_fix.c` (+ `Makefile`) — the LD_PRELOAD shim that makes the
  legacy 32-bit audio + signal pipeline survive on modern x86_64 kernels
  (shipped pre-built as `bin/sigio_fix.so`; rebuild with `make`)
* `start.sh` for quick testing in any graphical session
* `install.sh` for production: a tiny systemd unit that runs the
  emulator as root **inside your existing graphical session**, plus
  optional cross-distro display-manager autologin (GDM / SDDM /
  LightDM). No kiosk transformation, no GDM/SDDM/LightDM disable,
  no `getty` fight, no extra apt packages.

`nucore` itself is the upstream Big Guy's Pinball 2.25.3R build (extracted from
the official Lubuntu deb in FlipperFiles). It is not modified here.

### Command shape

```text
./start.sh [launcher options] [game] [nucore options]
```

Examples:

```sh
# Safe desktop launches
./start.sh --no-reboot                         # SWE1, fullscreen defaults
./start.sh --no-reboot swe1_14 -window         # SWE1 in a window
./start.sh --no-reboot rfm_15 -window          # RFM in a window
./start.sh --no-reboot auto -fullscreen        # let Nucore detect the game

# Pinbox fork
./start.sh --pinbox --no-reboot swe1_14 -window
./start.sh --pinbox --no-reboot rfm_15 -fullscreen -bpp 16

# Cabinet I/O
./start.sh --no-reboot swe1_14 -parallel 0x378
./start.sh --asix --no-reboot swe1_14 -parallel 0x378

# Production cabinet runners: intentionally omit --no-reboot
./start.sh swe1_14 -fullscreen -bpp 16
./start.sh --pinbox rfm_15 -fullscreen -bpp 16

# Privilege and desktop-inhibitor diagnostics
./start.sh --no-reboot --root=run0 swe1_14 -window
./start.sh --no-reboot --root=pkexec swe1_14 -window
./start.sh --no-reboot --root=sudo swe1_14 -window
./start.sh --no-reboot --no-root --no-inhibit swe1_14 -window

# Send everything after -- directly as the game/argument portion
./start.sh --no-reboot -- swe1_14 -window -bpp 16 -nojukeplay
```

### Launcher option reference

| Option | Default | Effect |
|---|---|---|
| `--no-reboot` | off | Select the safe testing runner and no-watchdog emulator binary |
| `--pinbox` | off | Run the Pinbox fork instead of Nucore |
| `--asix` | off | Add the ASIX `libftchipid` overlay for USB-to-serial cabinet I/O |
| `--sdl12-compat` | off | **Experimental:** translate SDL 1.2 calls to bundled SDL 2 |
| `--no-shim` | off | **Experimental:** do not preload `sigio_fix.so` |
| `--no-audio-shim` | off | Keep RTC/SIGIO protection but disable the shim's mixer-buffer and realtime-scheduling changes |
| `--no-sigio-shim` | off | Disable RTC/SIGIO protection while leaving the selected mode's audio behavior unchanged; diagnostic only |
| `--root=run0` | auto | Force systemd `run0` privilege escalation |
| `--root=pkexec` | auto | Force polkit `pkexec` privilege escalation |
| `--root=sudo` | auto | Force classic `sudo` privilege escalation |
| `--root=none` / `--no-root` | auto | Refuse escalation; useful only when capabilities are already present or for limited tests |
| `--no-inhibit` | off | Do not prevent desktop idle, locking, sleep, or lid actions |
| `--` | — | Stop parsing launcher options |
| `-h`, `--help` | — | Print launcher help and exit |

Nucore options use a single dash and are passed through unchanged. Common
examples include `-window`, `-fullscreen`, `-bpp 16`, `-parallel 0x378`, and
`-nojukeplay`.

### Games

| Name | Game |
|---|---|
| `swe1_14` or `swe1` | Star Wars Episode 1 — Revision 1.4 *(default)* |
| `rfm_15` or `rfm` | Revenge From Mars — Revision 1.5 |
| `auto` | Ask Nucore to detect the game |

### Nucore command-line reference recovered from the binary

The original manual is not required for this table. The option names,
argument requirements, validation ranges, switch behavior and diagnostic
messages were recovered directly from the stripped executables. `nucore` and
`nucore_nwd` share the current Nucore table. Pinbox has the same public
options but a few extra hidden ones, documented separately below.

Nucore expects **one dash**, for example `-window`, not `--window`. Put these
options after the game name when using `start.sh`.

#### Options printed by Nucore's embedded help

| Nucore option | Argument | Effect |
|---|---:|---|
| `-nojukeplay` | none | Disable jukebox-song playback |
| `-genplaylist` | none | Scan the jukebox content and generate a new playlist; this can write playlist data |
| `-flipscreen` | none | Rotate the displayed video upside down for cabinet mounting |
| `-fullscreen` | none | Request fullscreen video |
| `-window` | none | Request windowed video |
| `-bpp 16` | `16` | Use the 16-bit renderer expected by the original cabinet presentation |
| `-bpp 32` | `32` | Use the 32-bit renderer; every other value is rejected |
| `-parallel ADDRESS` | hexadecimal address | Redirect the emulated parallel port to a real host LPT address, normally `0x378` |

`-fullscreen` and `-window` set opposite values; if both are supplied, the
last one parsed wins. Command-line values are processed after `pb2k.cfg`, so
they override the corresponding loaded configuration for that run.

#### Functional options omitted from the embedded help

| Nucore option | Argument | Recovered behavior | Recommendation |
|---|---:|---|---|
| `-nice N` | integer `-20` through `20` | Set Nucore's requested Unix nice value | Advanced diagnostics only; negative values require privilege |
| `-nopause` | none | Disable Nucore's pause support | Useful if cabinet focus/pause behavior is undesirable |
| `-nowatermark` | none | Start with the watermark disabled | Safe presentation option |
| `-mdelay N` | integer microseconds | Set an internal emulation delay; Nucore confirms `Delay set to N us` | Timing experiment only |
| `-testvar N` | integer microseconds | Set an internal test variable; exact downstream purpose is not named in the stripped binary | Developer archaeology only |
| `-serial SPEC` | backend specification | Add an emulated serial backend; the binary accepts up to four | Advanced; syntax is inherited from its embedded QEMU core |

The embedded serial backend contains support strings for `null`, `stdio`,
`file:PATH`, `pipe:PATH` and device paths under `/dev`. This project does not
currently depend on `-serial`; prefer `--asix` for the supported ASIX cabinet
adapter path.

#### Extra Pinbox options

Select this executable family with `--pinbox`. `pinbox` and `pinbox_nwd`
support all of the public and functional options above, plus these two:

| Pinbox option | Argument | Recovered behavior | Recommendation |
|---|---:|---|---|
| `-gamma N` | number `1` through `10` | Set the renderer gamma value; values outside the range are rejected | Presentation tuning |
| `-nothreads` | none | Disable all Pinbox emulation threads and force 32-bit rendering | Diagnostic fallback only |

For example:

```sh
./start.sh --pinbox --no-reboot swe1_14 -window -bpp 16 -gamma 2
./start.sh --pinbox --no-reboot swe1_14 -window -nothreads
```

The Pinbox parser also consumes `-slideppause ARG`, but its dispatch entry has
no implementation. Supplying it has no recovered effect, so it is not a
usable feature.

#### Examples using recovered options

```sh
# Presentation
./start.sh --no-reboot swe1_14 -window -bpp 16 -flipscreen
./start.sh --no-reboot rfm_15 -fullscreen -bpp 32 -nowatermark

# Jukebox behavior
./start.sh --no-reboot swe1_14 -window -bpp 16 -nojukeplay
./start.sh --no-reboot swe1_14 -window -bpp 16 -genplaylist

# Focus/pause and scheduling diagnostics
./start.sh --no-reboot swe1_14 -window -bpp 16 -nopause
./start.sh --no-reboot swe1_14 -window -bpp 16 -nice -10

# Internal timing experiments: record the baseline before changing these
./start.sh --no-reboot swe1_14 -window -bpp 16 -mdelay 100
./start.sh --no-reboot swe1_14 -window -bpp 16 -testvar 100

# Real cabinet parallel port
./start.sh --no-reboot swe1_14 -fullscreen -bpp 16 -parallel 0x378
```

When you provide any Nucore option, spell out `-window` or `-fullscreen` and
the desired `-bpp` explicitly. The launcher's automatic
`-fullscreen -bpp 16` pair is added only when no Nucore options were supplied.

#### Low-level positional forms and legacy entries

The binary itself accepts `?`, `-h` or `--h` as its first argument to print
its small embedded help screen. `start.sh` handles `-h` and `--help` as
launcher help instead.

The binary can also accept a path ending in `.cfg` before the game name and
prints `Using config file: ...`. The portable launcher intentionally uses the
shipped `config/pb2k.cfg` path and does not expose arbitrary config paths as a
normal high-level argument.

Four additional names exist in the parser table: `-net ARG`, `-s`, `-p ARG`
and `-d ARG`. Disassembly confirms that this Nucore parser recognizes and
consumes them but performs no option-specific action. They appear to be dead
compatibility remnants from the embedded emulator core and should not be used.

Pinbox retains those dead compatibility entries and also recognizes
`-tftp ARG` and `-redir ARG`; all dispatch below the implemented option range
and have no recovered effect. The archival `nucore.225` resembles the current
Nucore table, while `nucore.old` resembles the Pinbox table. They are retained
as historical binaries and are not selected by `start.sh`.

### Runner and binary selection

| Launcher options | Runner | Emulator | Intended use |
|---|---|---|---|
| *(none)* | `run` | `nucore` | Production watchdog; may hard-reboot the host |
| `--no-reboot` | `runrd` | `nucore_nwd` | Safe Nucore desktop testing |
| `--pinbox` | `run` | `pinbox` | Production Pinbox watchdog |
| `--pinbox --no-reboot` | `run_pb_rd` | `pinbox_nwd` | Safe Pinbox desktop testing |

The SDL implementation and the two shim halves are independent:

| SDL implementation | Shim | Command fragment | Status |
|---|---|---|---|
| Native SDL 1.2 | enabled | `--no-reboot` | Established default |
| Native SDL 1.2 | signal only | `--no-reboot --no-audio-shim` | Diagnose audio intervention |
| Native SDL 1.2 | audio only | `--no-reboot --no-sigio-shim` | Diagnose signal intervention; boot may fail |
| Native SDL 1.2 | disabled | `--no-reboot --no-shim` | Experimental |
| SDL 1.2 API on SDL 2 | enabled | `--no-reboot --sdl12-compat` | Experimental modernization |
| SDL 1.2 API on SDL 2 | signal only | `--no-reboot --sdl12-compat --no-audio-shim` | Known to risk audio underruns |
| SDL 1.2 API on SDL 2 | audio only | `--no-reboot --sdl12-compat --no-sigio-shim` | Boot-safety experiment |
| SDL 1.2 API on SDL 2 | disabled | `--no-reboot --sdl12-compat --no-shim` | Most experimental |

Copy-paste A/B test:

```sh
./start.sh --no-reboot swe1_14 -window
./start.sh --no-reboot --no-shim swe1_14 -window
SDL12COMPAT_DEBUG_LOGGING=1 ./start.sh --no-reboot --sdl12-compat swe1_14 -window
SDL12COMPAT_DEBUG_LOGGING=1 ./start.sh --no-reboot --sdl12-compat --no-shim swe1_14 -window
```

Expected markers:

```text
[sigio_fix] loaded — ... sigio=... audio=...   # reports active shim halves
INFO: sdl12-compat 1.2.68, ... SDL2 2.26.5     # SDL 2 path is active
*** EXPERIMENT: sigio_fix.so is NOT loaded *** # --no-shim is active
```

`--sdl12-compat`, the shim controls, and `--asix` compose with each other. No
option installs or replaces host libraries. Native SDL 1.2 and the shim remain
the production defaults because desktop success does not validate real cabinet
RTC/SIGIO interrupts, fullscreen timing, or cabinet input/output.

### Audio selection

Audio defaults to `AUDIODEV=sysdefault`, which normally reaches PulseAudio or
PipeWire through the bundled 32-bit ALSA Pulse plugins. Override it only for
diagnostics:

```sh
AUDIODEV=default ./start.sh --no-reboot swe1_14 -window
AUDIODEV=hw:0 ./start.sh --no-reboot swe1_14 -window
```

Direct `hw:0` access bypasses desktop mixing and may fail when PipeWire or
PulseAudio owns the device.

### Privilege behavior

`start.sh` auto-detects how to grant raw I/O and real-time scheduling access.
It tries existing privileges, then `run0`, `pkexec`, and `sudo`. Display and
runtime variables are explicitly forwarded so the elevated emulator remains
inside the current graphical session. `systemd-inhibit` prevents locking,
sleep, and lid actions while it runs.

After `./install.sh`, the system unit already runs with the required privilege
and launches Nucore inside the logged-in user's slice. See “Privileges” below
for the detailed flow.

## Production install (autostart in your graphical session)

```sh
./install.sh
```

(`install.sh` re-launches itself under `run0` / `sudo` / `pkexec`
automatically — no need to be in the sudoers file on Debian 13.)

This install is deliberately **non-invasive**. It does **not** disable
GDM/SDDM/LightDM, does **not** change the default systemd target, does
**not** touch `getty@tty1`, does **not** mask sleep/suspend/hibernate,
does **not** mask notification daemons, and does **not** install any
apt packages. The desktop you have today is the desktop you have
tomorrow — nucore just shows up fullscreen on top of it.

### What gets written

| Path | Purpose |
|---|---|
| `/etc/systemd/system/nucore.service` | root-owned unit, `WantedBy=graphical.target`, runs `bin/nucore-as-root.sh` |
| `/etc/polkit-1/rules.d/49-nucore.rules` | scoped to `nucore.service` only — lets the active local-session user `systemctl start nucore` without password |
| `/etc/gdm3/daemon.conf` *(if GDM installed)* | sentinel-fenced `[daemon] AutomaticLogin=…` block; `.nucore-bak` backup created |
| `/etc/gdm/custom.conf` *(if Fedora/Arch GDM installed)* | same as above |
| `/etc/sddm.conf.d/49-nucore.conf` | drop-in `[Autologin] User=…` for SDDM (Kubuntu, KDE neon, openSUSE-Plasma, Manjaro-KDE) |
| `/etc/lightdm/lightdm.conf.d/49-nucore.conf` | drop-in `[Seat:*] autologin-user=…` for LightDM (Lubuntu, Xubuntu, Mint XFCE/Cinnamon) |

Polkit, GDM, SDDM and LightDM are all configured via files only — no
new packages get installed. The SDDM and LightDM drop-ins are written
**unconditionally**, so if you later `apt install kubuntu-desktop`
(pulling in SDDM) the autologin keeps working with no second `install.sh`
run. GDM is the one exception (its config dirs are package-owned), so
re-run `./install.sh` if you switch to a GNOME desktop later.

### Interactive prompts

You'll be asked, one by one:

* default game on boot (`swe1_14` / `rfm_15` / `auto`)
* boot the pinbox fork instead of nucore (default no)
* auto-launch on graphical login (default yes)
* enable display-manager autologin (default yes), and which user

`install.sh` defaults the autologin user to whoever invoked it
(detected via `$SUDO_UID` / `$PKEXEC_UID` / `logname` — i.e. you).

### Boot flow after install

1. The box boots normally → display manager (GDM/SDDM/LightDM) appears
   exactly as before, then **autologins straight to your desktop**.
2. `nucore.service` starts in parallel and waits for **two** signals
   before doing anything visible:
    * an active local user session (`Class=user`, `uid >= 1000`) — so
      it never attaches to the greeter session by mistake;
    * your `--user` `graphical-session.target` is `active` — i.e. your
      gnome-shell / KWin / XFCE session has finished its own startup
      (panel painted, autostart apps launched). This is the canonical
      "desktop is fully up" signal on every modern systemd desktop.
3. Wrapper harvests the session env (`DISPLAY`, `WAYLAND_DISPLAY`,
   `XAUTHORITY`, **`DBUS_SESSION_BUS_ADDRESS`**, `XDG_SESSION_ID`,
   `XDG_SESSION_TYPE`, `XDG_RUNTIME_DIR`) directly from
   `systemctl --user show-environment`.
4. `systemd-run --scope --slice=user-<uid>.slice --uid=0` launches the
   emulator **inside your user's own slice**. From the compositor's
   point of view nucore is a regular session app (just one that happens
   to be euid=0); it gets keyboard focus, plays nicely with screen
   savers, and exits clean to your desktop on `Esc` / F1.
5. A 3-second-deferred background helper calls
   `org.gnome.Shell.OverviewActive=false` (GNOME) or
   `org.kde.KWin.Effect.Overview1.deactivate` (KDE) over D-Bus, so
   freshly-autologged-in sessions don't leave nucore behind the
   Activities/Overview launcher.
6. `Esc` / F1 → nucore exits → the transient scope vanishes → the unit
   exits → you are back at your normal desktop. The unit only restarts
   on **failure** (`Restart=on-failure` with a 3-burst limit), never
   on a clean exit, so you can put the desktop on top intentionally.

### Manual control after install

```sh
systemctl start nucore          # start without rebooting (no auth prompt)
journalctl -u nucore -f         # follow logs
systemctl disable nucore        # stop autostarting at login
systemctl stop nucore           # close it from outside
```

### Reverse everything

```sh
./uninstall.sh
```

`uninstall.sh` is symmetric: stops the unit, removes the unit + the
polkit rule, strips the sentinel-fenced GDM block(s), deletes the
SDDM/LightDM drop-ins, `daemon-reload`s. Since `install.sh` never
touched GDM/SDDM/LightDM beyond its own block, never disabled the
display manager, never touched `getty` / sleep / notifications, and
never installed any packages, there is nothing else to restore.

## What's in the box

```
bin/                  binaries + launcher
  bundled.sh          re-exec wrapper around the bundled ld-linux
  nucore-as-root.sh   in-session bridge used by the systemd unit
  sigio_fix.so        LD_PRELOAD shim — fixes audio + signals on x86_64
  run                 production runner (watchdog, reboots host on stall)
  runrd               no-reboot runner (clean exit on crash)
  run_pb_rd           no-reboot runner for the pinbox fork
  nucore              Nucore 2.25.3R (production target)
  nucore.225          Nucore 2.25 base (kept for archeology)
  nucore.old          Older nucore (kept for archeology)
  nucore_nwd          Nucore with watchdog disabled (--no-reboot target)
  pinbox              Pinbox fork (production target with --pinbox)
  pinbox_nwd          Pinbox with watchdog disabled (--pinbox --no-reboot)
  n_update            Update installer (called from inside the emulator)
  n_update.old        Older n_update (kept for archeology)
src/                  source for our bits of the bundle
  sigio_fix.c         LD_PRELOAD shim source (rebuild with `make`)
  Makefile            builds ../bin/sigio_fix.so
bundlex86/            i386 shared libraries the bundle ships
  direct/             libs nucore links against directly
  indirect/           transitive deps + ld-linux.so.2
  alsa-lib/           32-bit Pulse ALSA plugin set
  asix/               ASIX libftchipid overlay (USB-to-serial cabinets)
  sdl12-compat/       opt-in SDL 1.2 ABI → SDL 2 translation overlay
roms/                 ROMs + savedata (.nvram, .flash, .ems, .see)
update/               *_update.bin (one update at a time — see below)
  swe1_14/            SWE1 update tree (latest official Williams: 0150)
  rfm_15/             RFM  update tree (latest official Williams: 0180)
                      Newer post-Williams firmware (Jim Askey at
                      mypinballs.com) is supported at runtime — see
                      the "Community updates" section below — but is
                      not redistributed here.
resources/            UI overlays, jukebox, watermark, load screens
config/               leds.cfg, pb2k.cfg, servers.txt
music/                jukebox playlist landing zone (empty by default)
install/              upstream nucore install assets (kept for reference)
```

## Community updates (mypinballs.com)

After Williams shipped the last official Pinball 2000 firmware in
September 2003, the platform has continued to be maintained by
**Jim Askey** at <https://mypinballs.com>. He produces newer firmware
revisions for both titles that add bug fixes, audio fixes, new
lighting / colour effects, and other gameplay refinements that the
community has wanted for years.

`nucore-portable` runs these bundles fine — they are **not**
"unsupported." The only thing this repo does **not** do is
redistribute the bundle files, at Jim's request. Please grab the
latest builds from his site directly so the version numbers you see
are always the current ones, and so the project that is keeping these
games alive stays supported.

| Game | Community version | Files (inside the 7z) start with |
|------|------------------:|----------------------------------|
| SWE1 | v2.10             | `pin2000_50069_0210_*`           |
| RFM  | v2.50             | `pin2000_50070_0250_*`           |
| RFM  | v2.60             | `pin2000_50070_0260_*`           |

nucore only loads **one** update at a time, and the `*_update.bin`
file must sit at the **root** of `update/`. To install a community
bundle:

1. Wipe the `update/` folder so no stale firmware files are left
   behind. Mixing files from two different firmware versions is the
   most common cause of boot failures.
   ```sh
   rm -rf update/*
   ```
2. Open the community archive, browse into whatever subfolder
   contains the `*_update.bin` plus the `pin2000_*` files /
   `gamelist.txt`, and extract those files **directly into** the
   now-empty `update/` folder — flat, no nested per-game directory.
3. Launch as usual. The game version printed on the boot screen
   should now reflect the community firmware.

To return to the official Williams firmware, repeat with the original
payload (a fresh `git checkout -- update/` from a clean clone is the
easiest way).

> **About the `.exe` files on mypinballs.com.** Despite the
> extension, the distributed bundles are plain archives — the `.exe`
> wrapper is just a self-extractor for Windows. On Linux / macOS any
> archive manager that understands the underlying format will list
> and extract their contents directly; you do not need to run the
> executable. Pick whatever extractor you already have installed and
> point it at the `.exe`.

## `sigio_fix.so` — default protection for audio, threads and signals

`bin/sigio_fix.so` is a 32-bit `LD_PRELOAD` shim shipped pre-built; the
source lives in `src/sigio_fix.c`. It remains enabled by default because the
original binaries assume old scheduling and signal-delivery behavior, and the
real cabinet RTC/SIGIO path has not been validated without it. Desktop hosts
can be tested with `--no-shim`, but a successful desktop run is not evidence
that a cabinet interrupt workload is safe.

The shim performs five small interventions. They are now split into signal
safety and audio stabilization:

1. **`sigaction` wrapper** — adds `SA_ONSTACK | SA_RESTART` to every
   `SIGALRM` / `SIGIO` handler the binary installs, and gives each
   thread its own 128 KB alternate signal stack. This is what stops
   the RTC/timer storm from corrupting the interrupted thread's stack
   (the original "segfault within seconds" symptom).
2. **`pthread_create` wrapper** — blocks `SIGIO` + `SIGALRM` in every
   child thread at birth, then bumps the thread to `SCHED_FIFO`
   priority 10 so the SDL_mixer audio callback always preempts
   `SCHED_OTHER` work. This is the part that needs the process to have
   `CAP_SYS_NICE` (i.e. run as root via `start.sh` / the systemd unit).
3. **`fcntl` wrapper** — rewrites `F_SETOWN(pid)` on the RTC fd into
   `F_SETOWN_EX(F_OWNER_TID, main_tid)`, so `SIGIO` is delivered only
   to the main thread instead of being randomly steered into SDL's
   audio/render threads (where the handler isn't safe to run).
4. **`Mix_OpenAudio` wrapper** — doubles the SDL_mixer chunk size from
   4096 → 8192 samples (~93 ms → ~186 ms of headroom at 44.1 kHz), so
   the residual scheduling jitter on a stock desktop kernel can't
   underrun the audio buffer. Latency cost is imperceptible for a
   pinball cabinet.
5. **`setpriority` wrapper** — silences the spurious "can't set nice"
   error path the original binary takes when it's already at the
   requested priority.

The signal protections (1, the signal-blocking half of 2, and 3) and audio
protections are enabled by default with both native SDL 1.2 and SDL12-compat;
both paths can underrun without the audio half. `--no-audio-shim` leaves only
signal protection. `--no-sigio-shim` disables signal protection while leaving
that mode's audio choice unchanged, and `--no-shim` disables the entire
library for controlled A/B testing.

### Rebuilding

The `.so` is shipped pre-built but you can rebuild it from source if you
need to (e.g. after editing `src/sigio_fix.c`):

```sh
sudo dpkg --add-architecture i386            # Debian/Ubuntu, once
sudo apt install gcc-multilib libc6-dev-i386 # Fedora: glibc-devel.i686
                                             # Arch:   lib32-glibc + multilib gcc
make                                         # from the bundle root —
                                             # writes bin/sigio_fix.so
```

The shim is loaded by `bin/bundled.sh` via the bundled
`ld-linux.so.2 --preload sigio_fix.so` argument (see the next section
for why `--preload` and not `LD_PRELOAD=`).

## How the launcher works (one paragraph)

`start.sh` parses `--no-reboot` / `--pinbox` / `--asix` /
`--sdl12-compat` / `--no-shim` to pick a
`(runner, binary)` pair, then calls
`bin/bundled.sh <mode> bin/<runner> bin/<binary> <game> <args>`. The runner
binary `execv()`s back into `bundled.sh`; the second entry is detected via the
`_BUNDLED_BINARY` env var and finally exec's the real emulator through the
bundled `ld-linux.so.2 --preload sigio_fix.so`. Its library path is an
optional overlay followed by `bundlex86/direct:bundlex86/indirect`. Passing
`--preload` to `ld-linux` directly (instead of `LD_PRELOAD=`) is what makes
the default preload survive the runner→exec wrap. `--no-shim` deliberately
omits that loader argument for the current launch.

## Real cabinet I/O

* **LPT (parallel port)**: `./start.sh swe1_14 -parallel 0x378`
* **USB-to-serial via ASIX FTDI**: `./start.sh --asix swe1_14`

## Caveats

* Audio defaults to `sysdefault` (PulseAudio / PipeWire). See “Audio
  selection” above before using direct hardware devices.
* x86_64 Linux only. Running on ARM hosts would need an extra i386-on-ARM
  layer (qemu-user) which is out of scope here.
* The legacy nucore EULA (in `install/`) restricts modification, but allows
  redistribution of unmodified copies. This bundle redistributes nucore
  unmodified; only the launcher + bundle around it are new.

## Privileges (no more `sudo run nucore`)

The original cabinet command was `sudo run nucore swe1_14`. On stock
Debian 13 the user is no longer in the sudoers file — `sudo` says "user
not in sudoers" and refuses. nucore-portable handles this transparently:

* **Dev / desktop launches (`./start.sh`)** auto-detect the escalation
  tool, in order: nothing-needed (caps already inherited from a parent
  unit) → `run0` (systemd ≥256 / Debian 13: pops a proper polkit GUI
  auth dialog, no sudoers required) → `pkexec` (older polkit) → `sudo`
  (classic, requires sudoers).
* **Display-server env preservation.** All three escalators are
  invoked with explicit forwarding of `$DISPLAY` / `$XAUTHORITY` /
  `$WAYLAND_DISPLAY` / `$XDG_RUNTIME_DIR` / `$HOME`:
    * `run0 --setenv=DISPLAY --setenv=XAUTHORITY ...`
    * `sudo --preserve-env=DISPLAY,XAUTHORITY,...`
    * `pkexec /usr/bin/env DISPLAY=... XAUTHORITY=... ...` (pkexec
      strips env unconditionally, so we re-inject inside).

  Without this, run0/pkexec would strip those vars when crossing the
  privilege boundary, SDL would fall back to direct framebuffer/DRM
  rendering, and the resulting fight with the running compositor would
  freeze the GNOME session (1:1 top-left window, rest of screen black,
  then session lock-out). With the explicit forwarding, root can read
  the user's `$XAUTHORITY` cookie file directly and SDL connects to
  X/Wayland normally.
* **Idle / lock suppression.** Every launch is also wrapped in
  `systemd-inhibit --what=idle:sleep:handle-lid-switch:handle-power-key:handle-suspend-key`,
  registered against your current logind session. As long as nucore is
  running, the surrounding GNOME/KDE desktop will not auto-idle, lock
  the screen, dim, suspend or react to the lid closing — same API
  GNOME's own video player uses. The inhibitor is held on *your*
  session, so it works even when escalation puts nucore itself in a
  different session view.
* **In-session install (`./install.sh`)** is the production path and is
  the simplest from a runtime point of view: the system unit runs as
  uid=0 (so `CAP_SYS_RAWIO` + `CAP_SYS_NICE` are already in the bag,
  no `AmbientCapabilities` gymnastics needed), and `bin/nucore-as-root.sh`
  uses `systemd-run --scope --slice=user-<uid>.slice --uid=0` to launch
  the emulator **inside your user's own logind slice**. From the
  compositor's point of view nucore is just another session app — it
  gets keyboard focus, idle inhibitors track the right scope, and
  `Esc` / F1 returns you cleanly to your desktop. The wrapper waits
  for `graphical-session.target` to be `active` (the canonical "desktop
  is fully up" signal on every modern systemd desktop) before doing
  anything visible, so it never races mutter/KWin during their startup.
  A polkit rule scoped to `nucore.service` only lets the active user
  `systemctl start nucore` without a password.

**Override flags:** `--root=run0|pkexec|sudo|none` forces a specific
tool; `--no-root` skips escalation entirely (only useful when caps are
already in place, e.g. inside the systemd unit); `--no-inhibit` skips
the `systemd-inhibit` wrap.

Note on `setcap`: file capabilities on `bin/nucore` would *not*
survive the `ld-linux.so.2 --library-path …` exec wrap that
`bundled.sh` does (the kernel checks caps on the file actually
exec'd, which is the loader). Running the system unit as uid=0 (the
production install) sidesteps this entirely; for `./start.sh`
launches we go through `run0` / `pkexec` / `sudo` instead.

## Provenance

* `bin/{nucore, nucore.225, nucore.old, run, n_update, n_update.old}` —
  extracted from `FlipperFiles/Files/Lubuntu_packages/nucore-2.25.3r-package-v003-wahcade.deb`
* `bin/{nucore_nwd, runrd, run_pb_rd, pinbox_nwd, sigio_fix.so}` — local
  builds with the watchdog reboot path neutralised (testing variants)
* `bin/pinbox` — the pinbox fork of nucore
* `bundlex86/` — pre-curated i386 system libraries (libc, libSDL, libmpg123,
  libasound, ld-linux.so.2, etc.) collected from Debian/Ubuntu i386 packages
* `bundlex86/alsa-lib/` — Debian i386 Pulse ALSA configuration, PCM and control
  plugins used to avoid host multiarch dependencies
* `bundlex86/sdl12-compat/` — Debian 13 i386 `sdl12-compat` 1.2.68-3;
  checksum and full redistribution notices are included beside the binary
* `roms/`, `update/` — extracted from `FlipperFiles/Roms/Nucore/nucore-roms.tar.gz.*`
* `resources/`, `config/`, `install/` — from the same upstream nucore deb
```
