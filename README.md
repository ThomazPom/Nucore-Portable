# nucore-portable

A self-contained, x86_64-friendly bundle of the legacy 32-bit Pinball 2000
emulator (`nucore`) and its `pinbox` fork. Drop it on a stock Debian 13 (or
similar) x64 machine, run `./start.sh`, and you get a working pinball without
ever touching `dpkg --add-architecture i386` or chasing 32-bit `.so` packages.

## Drop-in summary

The whole repo is designed to be a **drop-in cabinet brain replacement**:

```sh
git clone <this-repo> nucore-portable
cd nucore-portable
./start.sh           # smoke-test it on your desktop, no install needed
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
  bundled loader with a runtime-injected `sigio_fix.so`
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

## Quickstart

```sh
git clone <this-repo> nucore-portable
cd nucore-portable
./start.sh                              # production: run + nucore + swe1_14 fullscreen
./start.sh rfm_15                       # production: run + nucore + rfm_15
./start.sh --no-reboot                  # dev variant: runrd + nucore_nwd
./start.sh --pinbox                     # production pinbox fork
./start.sh --pinbox --no-reboot         # dev pinbox
./start.sh --asix swe1_14 -parallel 0x378   # ASIX USB→serial + LPT
./start.sh --no-reboot rfm_15 -window   # windowed dev session
```

Valid game names (the values nucore itself accepts):

| Name | Game |
|---|---|
| `swe1_14` | Star Wars Episode 1 — Revision 1.4 *(default)* |
| `rfm_15` | Revenge From Mars — Revision 1.5 |
| `auto` | auto-detect game |

The short aliases `swe1` / `rfm` are also accepted and rewritten to the
canonical `swe1_14` / `rfm_15`.

`start.sh` auto-detects how to grant nucore the raw I/O it needs
(parallel port, RT scheduling). On Debian 13 it uses `run0` (proper
polkit GUI auth dialog, no sudoers entry required). On older systems
it falls back to `pkexec`, then `sudo`. In all three cases the script
explicitly forwards `$DISPLAY` / `$XAUTHORITY` / `$WAYLAND_DISPLAY` /
`$XDG_RUNTIME_DIR` / `$HOME` across the privilege boundary, so SDL
keeps talking to your existing X/Wayland session — no framebuffer
fallback, no GNOME freeze. The launch is wrapped in `systemd-inhibit`
so the desktop will not auto-lock, dim, suspend or react to the lid
closing while you are playing.

After `./install.sh`, none of that escalation chain is invoked at
runtime: the system unit is already root, and the wrapper exec's nucore
into the user's own logind slice (so gnome-shell / KWin treat it as a
session app, not as an alien root grab). Press `Esc` or use the in-game
coin-door menu to exit cleanly back to your desktop. See "Privileges"
below for the full picture.

## Production vs. testing — the four modes

| Modifiers | Runner | Binary | When to use |
|---|---|---|---|
| *(none)* — default | `run` | `nucore` | **Production**: full watchdog, hard-reboots the host on stall |
| `--no-reboot` | `runrd` | `nucore_nwd` | **Desk testing**: emulator dies cleanly on crash, no host reboot — safe for patching |
| `--pinbox` | `run` | `pinbox` | Production pinbox fork |
| `--pinbox --no-reboot` | `run_pb_rd` | `pinbox_nwd` | Desk testing of the pinbox fork |

`--asix` is orthogonal to the four modes above: it overlays the ASIX
`libftchipid` for USB-to-serial cabinet adapters.

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
  asix/               ASIX libftchipid overlay (USB-to-serial cabinets)
roms/                 ROMs + savedata (.nvram, .flash, .ems, .see)
update/               *_update.bin per game (latest official Williams)
  swe1_14/            SWE1 update tree (active: 0150)
  rfm_15/             RFM  update tree (active: 0180)
                      Newer post-Williams firmware (Jim Askey at
                      mypinballs.com) is supported at runtime — drop the
                      bundle directory in alongside these and it Just
                      Works — but is not redistributed here. See the
                      "Community updates" section below.
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

| Game | Version | Bundle directory pattern              |
|------|--------:|---------------------------------------|
| SWE1 | v2.10   | `pin2000_50069_0210_*_B_10000000`     |
| RFM  | v2.50   | `pin2000_50070_0250_*_B_10000000`     |
| RFM  | v2.60   | `pin2000_50070_0260_*_B_10000000`     |

To use them, drop the extracted bundle directory under `update/`
alongside `swe1_14/` / `rfm_15/`. nucore picks the highest-versioned
tree per game at startup, so the new bundle becomes "active" without
any further configuration. The bundle directories themselves are
gitignored so an accidental commit can never republish them.

If you have an original cabinet, supporting Jim is also the way to
get the hardware spares and licences you may need.

## `sigio_fix.so` — what it is, why it's mandatory on x86_64

`bin/sigio_fix.so` is a 32-bit `LD_PRELOAD` shim shipped pre-built; the
source lives in `src/sigio_fix.c`. **It is not optional** — without it
the legacy nucore/pinbox audio pipeline crashes on any post-2010 kernel
+ glibc (the original binaries were built against GCC 4.2.4-era glibc
and ALSA, and assume scheduling / signal-delivery semantics that no
longer hold). With it loaded, the emulator boots and stays up.

The shim performs five small interventions, all surgical:

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

`start.sh` parses `--no-reboot` / `--pinbox` / `--asix` to pick a
`(runner, binary)` pair, then calls
`bin/bundled.sh <mode> bin/<runner> bin/<binary> <game> <args>`. The runner
binary `execv()`s back into `bundled.sh`; the second entry is detected via the
`_BUNDLED_BINARY` env var and finally exec's the real emulator through the
bundled `ld-linux.so.2 --preload sigio_fix.so --library-path
bundlex86/direct:bundlex86/indirect`. Passing `--preload` to `ld-linux`
directly (instead of `LD_PRELOAD=`) is what makes the preload survive the
runner→exec wrap — the env-var version was getting silently dropped, which
was the original "no sound on x64" symptom.

## Real cabinet I/O

* **LPT (parallel port)**: `./start.sh swe1_14 -parallel 0x378`
* **USB-to-serial via ASIX FTDI**: `./start.sh --asix swe1_14`

## Caveats

* Audio defaults to `sysdefault` (PulseAudio / pipewire). Override with
  `AUDIODEV=hw:0 ./start.sh`.
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
* `roms/`, `update/` — extracted from `FlipperFiles/Roms/Nucore/nucore-roms.tar.gz.*`
* `resources/`, `config/`, `install/` — from the same upstream nucore deb
```
