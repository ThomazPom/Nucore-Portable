# nucore-portable

A self-contained, x86_64-friendly bundle of the legacy 32-bit Pinball 2000
emulator (`nucore`) and its `pinbox` fork. Drop it on a stock Debian 13 (or
similar) x64 machine, run `./start.sh`, and you get a working pinball without
ever touching `dpkg --add-architecture i386` or chasing 32-bit `.so` packages.

> [!IMPORTANT]
> **Real Pinball 2000 cabinet tested.** In August 2026, Paul B. Fedele
> installed `Nucore-Portable` and confirmed it working on an actual Pinball
> 2000 cabinet. His video documents the installation, terminal output and
> running machine:
> **[watch the real-cabinet installation and test on YouTube](https://www.youtube.com/watch?v=cwnoy5SBgOg)**.
>
> **[Original test report](https://github.com/ThomazPom/Encore-Pinball2000/issues/2)**

<p align="center">
  <a href="https://www.youtube.com/watch?v=cwnoy5SBgOg">
    <img src="https://img.youtube.com/vi/cwnoy5SBgOg/hqdefault.jpg"
         alt="Nucore-Portable installed and running on a real Pinball 2000 cabinet"
         width="640">
  </a>
</p>

## Quick start

Start with a harmless windowed test. These three lines are ready to paste:

```sh
git clone https://github.com/ThomazPom/Nucore-Portable.git
cd Nucore-Portable
./start.sh --no-reboot swe1_14 -window
```

This does not install anything or make persistent system changes. It runs Star
Wars windowed with the reboot watchdog disabled. The bundle carries its own
32-bit loader and libraries, so a stock x86_64 Debian system does not need
multiarch packages. An authentication prompt may appear because Nucore needs
raw cabinet-I/O and scheduling privileges while it runs.

If that works, fullscreen is still a safe test:

```sh
./start.sh --no-reboot swe1_14 -fullscreen -bpp 16
```

Keep `--no-reboot` for experiments. Plain `./start.sh` selects the production
watchdog, which may hard-reboot a cabinet PC after a stall.

## When the test works: optional cabinet integration

You can stop with the commands above and launch Nucore manually forever.
`install.sh` is only for owners who want the machine to behave like a cabinet:
automatic login, automatic Nucore startup, and a clean return to the desktop
with F1 or Esc.

The installer makes real system changes, listed below. They are deliberately
scoped and reversible, but this is not a zero-touch operation. Read the list,
then run:

```sh
./install.sh
```

(`install.sh` re-launches itself under `run0` / `sudo` / `pkexec`
automatically — no need to be in the sudoers file on Debian 13.)

It does not disable GDM/SDDM/LightDM, change the default systemd target, touch
`getty@tty1`, mask sleep/suspend/hibernate or notification daemons, or install
APT packages. It does add a system service and polkit rule, and can configure
display-manager autologin. `./uninstall.sh` reverses those project-owned
changes.

The installer does not copy the bundle into a system directory: the service
points back to this live clone. Keep the directory in place. To move it later,
run `./uninstall.sh`, move the clone, then run `./install.sh` again.

Paul's cabinet video is also an excellent example of Linux tuned as a dedicated
appliance: the boot is unusually fast and the transition into Nucore is nearly
seamless. The installer provides the service, autologin and graphical-session
handoff described here. Total boot time still depends on the PC firmware,
storage, desktop and services enabled on that particular machine; it does not
silently apply every operating-system optimization demonstrated in the video.

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
* optional custom `.cfg` file (blank keeps the launcher defaults)
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
never installed any packages, there is nothing else to restore. It deliberately
retains the `.nucore-bak` safety copies because it cannot prove that a backup
with that name did not predate the installer.

## Cabinet I/O and compatibility experiments

* **LPT (parallel port)**: `./start.sh swe1_14 -parallel 0x378`
* **ASIX `.so.6` compatibility experiment**: `./start.sh --asix --no-reboot swe1_14`

### Nucore function keys

These are Nucore controls, not launcher shortcuts:

| Key | Function |
|---|---|
| `F1` | Exit Nucore; after cabinet integration this returns to the desktop |
| `F2` | Toggle the screen upside down, useful while servicing the display |
| `F3` | Decrease GI/light timing by one fine step |
| `F4` | Increase GI/light timing by one fine step |
| `F5` | Decrease GI/light timing by one coarse step |
| `F6` | Increase GI/light timing by one coarse step |

The F3–F6 adjustments compensate for GI-light flicker caused by timing
differences between PCs. Nucore saves the selected timing. The playfield relay
may click while it is being adjusted; the original manual says this is
expected. No Nucore functions are documented for F7–F12.

Source: [Nucore User Manual, revision 2.0A, “Nucore Keyboard Commands”](https://o.pinside.com/c/58/34/c5834df1bceaaa90b4b77475b3e32b0c27742530.pdf).

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

## Running and configuring Nucore

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

# Experimental ASIX libftchipid using libstdc++.so.6
./start.sh --asix --no-reboot swe1_14

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
| `--asix` | off | **Experimental:** select the newer ASIX `libftchipid` path that uses `libstdc++.so.6` instead of the original `.so.5` |
| `--sdl12-compat` | off | **Experimental:** translate SDL 1.2 calls to bundled SDL 2 |
| `--no-shim` | off | **Experimental:** do not preload `sigio_fix.so` |
| `--no-audio-shim` | off | Keep RTC/SIGIO protection but disable the shim's mixer-buffer and realtime-scheduling changes |
| `--no-sigio-shim` | off | Disable RTC/SIGIO protection while leaving the selected mode's audio behavior unchanged; diagnostic only |
| `--config FILE` | none | Load a custom Nucore `.cfg`; the file replaces implicit presentation defaults |
| `--root=run0` | auto | Force systemd `run0` privilege escalation |
| `--root=pkexec` | auto | Force polkit `pkexec` privilege escalation |
| `--root=sudo` | auto | Force classic `sudo` privilege escalation |
| `--root=none` / `--no-root` | auto | Refuse escalation; useful only when capabilities are already present or for limited tests |
| `--no-inhibit` | off | Do not prevent desktop idle, locking, sleep, or lid actions |
| `--` | — | Stop parsing launcher options |
| `-h`, `--help` | — | Print launcher help and exit |

`--asix` comes from an earlier, successful but still experimental compatibility
experiment. Nucore's original `libftchipid.so.0` depends on
`libstdc++.so.5`, which recent Debian releases no longer provide. The newer
`libftchipid` 0.1.0 binary downloaded from ASIX's official site instead uses
the readily available `libstdc++.so.6`. Its ABI packaging differs from the
Nucore build: it names `libftchipid.so` and `libftd2xx.so` rather than their
`.so.0` forms, so the experiment also required aliases and an alternate
`libltdl.so.3`. That is why it remains explicit rather than replacing the
known Nucore libraries by default.

The complete i386 ASIX set is bundled in `bundlex86/asix/`. Therefore these are
real A/B paths, not aliases for the same configuration:

```sh
./start.sh --no-reboot swe1_14 -window        # original libftchipid → libstdc++.so.5
./start.sh --asix --no-reboot swe1_14 -window # ASIX 0.1.0       → libstdc++.so.6
```

Both paths have reached game, video and audio initialization in controlled
desktop runs. The original `.so.5` path remains the default because those runs
do not replace long-duration or real-cabinet validation of the ASIX variant.

Nucore options use a single dash and are passed through unchanged. Common
examples include `-window`, `-fullscreen`, `-bpp 16`, `-parallel 0x378`, and
`-nojukeplay`. Every launch starts with the cumulative baseline
`-fullscreen -bpp 16 -nowatermark`; supplied options are appended afterward.

### Games

| Name | Game |
|---|---|
| `swe1_14` or `swe1` | Star Wars Episode 1 — Revision 1.4 *(default)* |
| `rfm_15` or `rfm` | Revenge From Mars — Revision 1.5 |
| `auto` | Ask Nucore to detect the game |

### Use a config file instead of repeating arguments

Nucore can load a complete configuration before the game starts. Copy the
shipped template, edit it once, and select it through the launcher:

```sh
cp config/pb2k.cfg config/cabinet.cfg
nano config/cabinet.cfg
./start.sh --no-reboot --config config/cabinet.cfg swe1_14
```

The file covers RGB gamma, fullscreen, screen
inversion, renderer depth, watermark, jukebox and playlist behavior, USB,
tournament/server settings, server ports and tick adjustment. It remains an
ordinary text file in the repository; the launcher does not rewrite it. The
positional game remains authoritative: omit it for the default `swe1_14`, or
name `rfm_15` / `auto` as usual.

Selecting `--config` suppresses the launcher's implicit
`-fullscreen -bpp 16 -nowatermark` baseline, so the file genuinely owns those
settings. Nucore arguments are still cumulative and optional. If present, they
come after the config and override it for that run:

```sh
./start.sh --no-reboot --config config/cabinet.cfg swe1_14 -window
```

`install.sh` asks for the same optional `.cfg` path and records it in
`nucore.service`, allowing an installed cabinet to boot entirely from the file
without a repeated argument list. Keep that file in place while the service is
installed.

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
currently depend on `-serial`. No repository evidence connects it to `--asix`,
so do not infer a serial-adapter configuration from that historical name.

#### Extra Pinbox options

Select this executable family with `--pinbox`. `pinbox` and `pinbox_nwd`
support all of the public and functional options above, plus these two:

| Pinbox option | Argument | Recovered behavior | Recommendation |
|---|---:|---|---|
| `-gamma N` | number `1` through `10` | Set the renderer gamma value; values outside the range are rejected | Presentation tuning |
| `-nothreads` | none | Disable all Pinbox emulation threads and force 32-bit rendering | Diagnostic fallback only |

On first use, `start.sh` (and the installer) also creates a missing
`roms/<game>_pinbox.bin` from the corresponding `<game>_nucore.bin`. It never
overwrites an existing Pinbox file. This is why `--pinbox` does not require a
manual sound-bank copy after cloning.

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

Launcher defaults and Nucore arguments are cumulative. The launcher always
places `-fullscreen -bpp 16 -nowatermark` first, followed by everything you
supplied. Because Nucore processes the arguments in order, later alternatives
override earlier ones: `-window` overrides implicit `-fullscreen`, and
`-bpp 32` overrides implicit `-bpp 16`. Independent switches such as
`-nojukeplay`, `-flipscreen` and `-nopause` simply join the baseline.

#### Low-level positional forms and legacy entries

The binary itself accepts `?`, `-h` or `--h` as its first argument to print
its small embedded help screen. `start.sh` handles `-h` and `--help` as
launcher help instead.

The binary accepts a path ending in `.cfg` before the game name and prints
`Using config file: ...`; `start.sh --config FILE` exposes this form safely and
resolves relative paths from the repository root.

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

### Optional modern compatibility paths

The launcher's design preserves several opt-in alternatives alongside its
conservative defaults: the ASIX `libftchipid` experiment for the move from
`libstdc++.so.5` to `.so.6`,
SDL12-compat for running the SDL 1.2 ABI over SDL 2, and controls for testing
each half of the preload shim. Such alternatives remain useful even when the
original stack works: they provide escape routes for distributions that stop
carrying an old dependency and controlled A/B tests when diagnosing a cabinet.

They are alternatives, not cumulative upgrades. Selecting more of them does
not inherently make Nucore faster, more accurate, more stable or better
sounding. Each substitutes one compatibility boundary and therefore exchanges
an old, known behavior for a newer but less cabinet-tested one. Use the smallest
change that solves an observed problem; the native SDL 1.2 path with the full
shim remains the default.

“Modern” is relative to Nucore, not shorthand for “latest.” The original
Nucore package is from 2018 and includes still older dependencies (the bundled
FTDI D2XX library is approximately 2010). The optional ASIX `libftchipid` 0.1.0
experiment is from 2011. At the newest end, the SDL bridge is Debian 13's
`sdl12-compat` 1.2.68-3 running over bundled SDL 2.26.5. Thus the alternatives
span several generations; this project claims provenance only up to those
named Debian 13 package versions, not that every bundled library is current.

#### Example: update SDL12-compat

This refreshes only the opt-in SDL12-compat library from the
version currently published by the host's configured Debian repositories. It
downloads and extracts the i386 package without installing it system-wide,
keeps the previous file, and updates the overlay symlink:

On a stock 64-bit installation, enable the i386 package index once (this
changes APT's known architectures but installs no packages):

```sh
sudo dpkg --add-architecture i386 && sudo apt update
```

```sh
cd Nucore-Portable
work=$(mktemp -d)
(cd "$work" && apt download libsdl1.2debian:i386)
dpkg-deb -x "$work"/libsdl1.2debian_*_i386.deb "$work/root"
candidate=$(find "$work/root" -type f -name 'libSDL-1.2.so.*' | head -n 1)
file "$candidate"
readelf -d "$candidate" | sed -n '/NEEDED/p'
cp -a bundlex86/sdl12-compat/libSDL-1.2.so.1.2.68 \
  bundlex86/sdl12-compat/libSDL-1.2.so.1.2.68.previous
install -m 0644 "$candidate" "bundlex86/sdl12-compat/$(basename "$candidate")"
ln -sfn "$(basename "$candidate")" bundlex86/sdl12-compat/libSDL-1.2.so.0
SDL12COMPAT_DEBUG_LOGGING=1 ./start.sh --no-reboot --sdl12-compat swe1_14 -window
```

This is an update procedure, not an assurance that the new build is better or
that all of its dependencies are already bundled. Confirm the printed version,
video, input and audio before removing the `.previous` rollback copy. The
command follows whatever Debian suite is configured in APT; it does not claim
to fetch a release newer than that suite.

#### Example: test a newer FTDI D2XX library

FTDI distributes D2XX separately rather than through Debian. Download the
**Linux x86 (32-bit)** archive from the [official FTDI D2XX page](https://ftdichip.com/drivers/d2xx-drivers/),
leave it in `~/Downloads`, then stage it as another opt-in overlay:

```sh
cd Nucore-Portable
work=$(mktemp -d)
archive=$(find "$HOME/Downloads" -maxdepth 1 -type f \
  \( -name 'libftd2xx*.tar.gz' -o -name 'libftd2xx*.tgz' \) | head -n 1)
tar -xf "$archive" -C "$work"
candidate=$(find "$work" -type f -path '*/release/build/libftd2xx.so.*' | head -n 1)
file "$candidate"                    # must report 32-bit Intel i386
readelf -d "$candidate" | sed -n '/SONAME\|NEEDED/p'
cp -a bundlex86/direct/libftd2xx.so.0 \
  bundlex86/direct/libftd2xx.so.0.previous
install -m 0644 "$candidate" bundlex86/direct/libftd2xx.so.0
./start.sh --no-reboot swe1_14 -window
```

Restore immediately if the test fails:

```sh
mv -f bundlex86/direct/libftd2xx.so.0.previous \
  bundlex86/direct/libftd2xx.so.0
```

A new D2XX release can change its required glibc baseline or runtime behavior
even when its SONAME looks compatible. It also does not update `libftchipid`:
those are separate libraries and must be evaluated separately. Keep such a
change local until desktop and real-cabinet tests pass.

#### Useful library one-liners

These are intentionally read-only unless the comment says **changes files**:

```sh
# Download both Debian SDL candidates without installing them (after enabling
# the i386 package index as shown above)
apt download libsdl1.2debian:i386 libsdl2-2.0-0:i386

# Download and immediately list the SDL12-compat package contents
apt download libsdl1.2debian:i386 && dpkg-deb -c libsdl1.2debian_*_i386.deb | sed -n '/libSDL-1.2.so/p'

# Show the SDL12-compat version offered by the configured Debian suite
apt-cache policy libsdl1.2debian:i386

# Prove which C++ runtime the original Nucore libftchipid requests
readelf -d bundlex86/direct/libftchipid.so.0 | sed -n '/NEEDED/p'

# Show the important libraries resolved by the conservative native path
bundlex86/indirect/ld-linux.so.2 --inhibit-cache --library-path bundlex86/direct:bundlex86/indirect --list bin/nucore_nwd | sed -n '/libSDL\|libftchipid\|libftd2xx\|libstdc++/p'

# Show the same resolution with SDL12-compat placed first
bundlex86/indirect/ld-linux.so.2 --inhibit-cache --library-path bundlex86/sdl12-compat:bundlex86/direct:bundlex86/indirect --list bin/nucore_nwd | sed -n '/libSDL\|libftchipid\|libftd2xx\|libstdc++/p'

# Check whether two candidate libraries are actually duplicates
sha256sum bundlex86/asix/libftd2xx.so bundlex86/direct/libftd2xx.so.0

# Inspect architecture, SONAME and dependencies before copying any candidate
file "$candidate" && readelf -d "$candidate" | sed -n '/SONAME\|NEEDED/p'

# Native/compat desktop A/B test (each command is independent)
./start.sh --no-reboot swe1_14 -window
SDL12COMPAT_DEBUG_LOGGING=1 ./start.sh --no-reboot --sdl12-compat swe1_14 -window

# Restore the originally bundled SDL12-compat target (**changes one symlink**)
ln -sfn libSDL-1.2.so.1.2.68 bundlex86/sdl12-compat/libSDL-1.2.so.0

# See every local library edit or replacement before committing
git status --short bundlex86 && git diff --stat -- bundlex86
```

The loader `--list` commands resolve dependencies without starting Nucore, so
they are the fastest way to verify that an overlay really wins the search path.
Matching SHA-256 values mean the files are identical regardless of their names.
Use `apt download` whenever Debian packages the library: unlike `apt install`,
it only saves the `.deb` in the current directory. The vendor download remains
necessary for FTDI D2XX because the current proprietary Linux release is not a
Debian package.

#### Choosing an SDL implementation

Neither SDL choice is universally "better"; they optimize for different
risks.

| | Native SDL 1.2 | SDL12-compat on SDL 2 |
|---|---|---|
| What runs | The original SDL 1.2 implementation Nucore was built and tested against | Nucore's unchanged SDL 1.2 calls translated at runtime to bundled SDL 2 |
| Main advantage | Fewest behavioral changes: original timing, surfaces, input and fullscreen semantics | A maintained compatibility bridge to a newer video, audio and input implementation |
| Modern-host potential | Predictable legacy behavior, but dependent on old SDL assumptions | May fit current display servers, audio stacks and input drivers better without modifying Nucore |
| Main risk | SDL 1.2 is obsolete and increasingly awkward on new desktops | Translation can subtly change timing, fullscreen, rendering, focus or input behavior |
| Project status | Production default and the conservative cabinet choice | Experimental alternative that is easy to test side by side; no blanket improvement claimed |

SDL12-compat is not a port of Nucore to SDL 2: the game still calls the SDL
1.2 API it knows. The compatibility library implements that ABI using SDL 2
underneath. This offers a modernization path without patching the stripped
emulator, but it cannot guarantee that every old edge case behaves identically.
Native SDL 1.2 therefore remains valuable even if SDL12-compat works perfectly
on a particular desktop.

In practical terms, SDL12-compat may benefit from SDL2's maintained driver
code, current X11/Wayland integration, newer audio-device handling and input
hotplug support. It also reduces dependence on an SDL 1.2 library that modern
distributions are gradually dropping. The bundle's audio route still starts
at `AUDIODEV=sysdefault`, so selecting SDL12-compat does not by itself replace
ALSA, PulseAudio or PipeWire; it modernizes the SDL layer above that route.

Native SDL 1.2 avoids the translation layer entirely. Its software-surface,
palette, event, timing and fullscreen behavior are the semantics the 2018
Nucore binary expected. That smaller regression surface—and the real-cabinet
success of the default configuration—is why it remains the production choice,
not because SDL12-compat lacks value.

| SDL implementation | Shim | Command fragment | Status |
|---|---|---|---|
| Native SDL 1.2 | enabled | `--no-reboot` | Established default |
| Native SDL 1.2 | signal only | `--no-reboot --no-audio-shim` | Diagnose audio intervention |
| Native SDL 1.2 | audio only | `--no-reboot --no-sigio-shim` | Diagnose signal intervention; boot may fail |
| Native SDL 1.2 | disabled | `--no-reboot --no-shim` | Experimental |
| SDL 1.2 API on SDL 2 | enabled | `--no-reboot --sdl12-compat` | Experimental modernization |
| SDL 1.2 API on SDL 2 | signal only | `--no-reboot --sdl12-compat --no-audio-shim` | Audio A/B diagnostic |
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
RTC/SIGIO interrupts, fullscreen timing, or cabinet input/output. Composition
means the switches can be tested together; it does not imply that stacking
them provides an additional benefit.

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
  asix/               complete ASIX libftchipid 0.1.0 / libstdc++.so.6 overlay
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

## `sigio_fix.so` — default protection for audio, threads and signals

`bin/sigio_fix.so` is a 32-bit `LD_PRELOAD` shim shipped pre-built; its source
lives in `src/sigio_fix.c`. The failures it addresses are not hypothetical:
audio instability and legacy signal/RTC failures were observed repeatedly for
years by this project's maintainer. Paul B. Fedele independently reported
audio trouble on older Linux audio stacks before confirming this bundle on his
cabinet. The wrappers below were written for concrete symptoms, not theoretical
ones. They remain enabled by default in every SDL, ASIX, Nucore and Pinbox
configuration.

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
   scheduling jitter has more room before it can underrun the buffer.
   The tradeoff is about 93 ms of additional buffering latency.
5. **`setpriority` wrapper** — silences the spurious "can't set nice"
   error path the original binary takes when it's already at the
   requested priority.

#### What the tests do—and do not—prove

Paul B. Fedele's real-cabinet report confirms that the complete Debian 13,
PipeWire and default Nucore-Portable stack works on physical Pinball 2000
hardware. He also reports that it cleared audio problems present on older
Linux installations during the ALSA-to-PulseAudio transition. That is strong
validation of the shipped configuration, but it is not an isolated test of
each shim wrapper.

For exact reproduction, repository HEAD at the time of Paul's August 2 test
was commit
[`81b0f72`](https://github.com/ThomazPom/Nucore-Portable/commit/81b0f72638940459e794c7bf042e3d08d46daa3b):

```sh
git clone https://github.com/ThomazPom/Nucore-Portable.git && git -C Nucore-Portable switch --detach 81b0f72
```

That command is historical test provenance. New installations should use the
current `main` quick start at the top of this README.

A current Kali desktop test did not reproduce gameplay underruns with
SDL12-compat; one underrun appeared only during program exit, while audio was
already being dismantled, and is harmless. That single host result does not
erase the long-running failures seen on other machines, exercise every real
cabinet RTC/SIGIO condition, or prove that either shim half is universally
unnecessary. Native SDL 1.2 has likewise not had a controlled comparison
across enough kernels, sound servers and cabinet workloads to overturn the
historical evidence.

For that reason the safe policy is deliberately conservative: both shim halves
stay enabled everywhere unless the user explicitly disables one for an A/B
test. A successful `--no-shim` run is useful evidence about that machine and
workload, not a general compatibility guarantee.

`--no-audio-shim` leaves only signal protection. `--no-sigio-shim` disables
signal protection while leaving that mode's audio choice unchanged, and
`--no-shim` disables the entire library for controlled A/B testing.

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

`start.sh` parses its runner, SDL, shim, privilege and inhibitor options, plus
an optional `--config FILE`, then picks a `(runner, binary)` pair and calls
`bin/bundled.sh <mode> bin/<runner> bin/<binary> [config.cfg] <game> <args>`.
The config is placed where Nucore expects it, before the game, while explicit
arguments remain last so they can override config values. The runner
binary `execv()`s back into `bundled.sh`; the second entry is detected via the
`_BUNDLED_BINARY` env var and finally exec's the real emulator through the
bundled `ld-linux.so.2 --preload sigio_fix.so`. Its library path is an
optional overlay followed by `bundlex86/direct:bundlex86/indirect`. Passing
`--preload` to `ld-linux` directly (instead of `LD_PRELOAD=`) is what makes
the default preload survive the runner→exec wrap. `--no-shim` deliberately
omits that loader argument for the current launch.

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
* `bundlex86/asix/libftchipid.so.0` — official ASIX i386 `libftchipid` 0.1.0;
  source URL, naming details and SHA-256 checksums are recorded in the adjacent
  `README.md`
* `roms/`, `update/` — extracted from `FlipperFiles/Roms/Nucore/nucore-roms.tar.gz.*`
* `resources/`, `config/`, `install/` — from the same upstream nucore deb
```
