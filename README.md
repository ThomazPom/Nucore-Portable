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

You can keep launching manually. For an appliance-like boot, run:

```sh
./install.sh
```

This repository has only one installer: the root-level `./install.sh` shown
above. The obsolete original Nucore installer and its `exec_nucore.service`
layout are no longer included.

Maintainers can reproduce a stripped Debian 13 netinstall and exercise the
installer repeatedly with disposable qcow2 overlays; see
[`tools/debian-qemu/`](tools/debian-qemu/README.md). The sealed post-netinst
base is never modified by a test.

The installer presents one flat choice of cabinet host:

| Choice | Session path | Role |
|---|---|---|
| **Existing display manager** | GDM/SDDM/LightDM → normal remembered desktop session | Recommended when available |
| **Gamescope** | console login → standalone Gamescope | Gaming/scaling-oriented |
| **Cage** | console login → Wayland kiosk | Minimal single application |
| **Weston** | console login → Weston kiosk shell | Reference Wayland stack |
| **Xorg** | console login → bare Xorg | Proven SDL 1.2/X11 path |
| **Framebuffer / direct console** | console login → SDL direct display | Lowest-level experimental path |

The display-manager choice is shown only when a supported manager exists. It
enables autologin into the user's already selected desktop session. GNOME,
Plasma or another installed desktop may therefore appear briefly and remains
behind the fullscreen game. Nucore Portable neither identifies nor disables
desktop-specific shells, panels or compositors. This is the generic price of
reusing an arbitrary distribution-managed graphical session.

Every standalone choice instead uses the same
`agetty → login → PAM/logind` foundation and starts only its
selected display backend. In both paths the selected account gets its normal
`XDG_RUNTIME_DIR`, D-Bus, `systemd --user`, audio and distribution services. It
does not need sudo or administrator membership.

In the standalone Xorg profile, the login session supplies PAM/logind, D-Bus
and audio, while the already-privileged `nucore.service` starts Xorg itself.
This lets Xorg acquire the cabinet VT directly and keeps display ownership and
Nucore lifecycle under the same root system service.

For standalone profiles, the installer records the cabinet account's login
shell and temporarily selects `/bin/sh`. Standard `/bin/login` completes PAM
and logind setup, then a tty1-only `/etc/profile.d` hook enters the cabinet
host. Uninstall restores the recorded shell unless someone changed it
independently after installation.

`nucore.service` remains a privileged system service. It waits for the real
user session to become ready, then launches Nucore as root. It gives that root
process a private, ephemeral runtime directory instead of falsely treating the
user-owned `/run/user/<uid>` as root's `XDG_RUNTIME_DIR`. Explicit validated
socket addresses connect it to the selected user's display, D-Bus and audio
services. In display-manager mode it reads only `DISPLAY`,
`XAUTHORITY` and `WAYLAND_DISPLAY` from the environment that the normal desktop
has already imported into `systemd --user`. This needs no autostart helper,
extra session definition or rendezvous file. Privilege never flows upward from
the autologged user. The same account can still be used independently through
SSH when an SSH server has been configured by the machine owner.

Standalone modes use an intentionally ephemeral rendezvous. During a run,
there is one mode-0600 file under `/run/user/<uid>/nucore-portable/`; `/run` is tmpfs,
not persistent storage. It is written through an atomic temporary rename, then
the service removes it to signal completion. The session removes the empty
directory as it exits. There is no PID file, lock file, separate “done” file,
daemon, socket helper or external IPC dependency.

That separation also requires a trusted checkout. A root service must not
silently execute files that the autologged account can replace. The installer
detects a user-writable checkout (including a writable parent directory), warns,
and requires explicit confirmation. A strict cabinet deployment should place the checkout
under a root-owned location such as `/opt/Nucore-Portable`; accepting the
warning instead explicitly treats the selected local account as trusted code.

Normal operation lets SDL discover its backend from the session environment.
One necessary exception is native SDL 1.2 in a graphical cabinet session: the
service selects X11 because SDL 1.2 has no Wayland backend and its root process
can otherwise prefer `fbcon`, bypassing Xorg/Xwayland and the compositor.
Xorg publishes `DISPLAY`; Cage, Weston and Gamescope publish their client
display; direct console publishes neither. Native SDL 1.2 and SDL12-compat/SDL2 then select a
backend that is actually present in their build and environment. `--console`
only unlocks the direct-display safety gate. The installer uses native SDL 1.2
for this profile and lets it discover fbcon. SDL2/KMSDRM remains a manual research path: on the
tested Intel/Kali host it crashed while changing display mode and left the VT
in graphics mode, so it is not offered as a cabinet configuration.

The standalone wrappers avoid selecting a DRM backend or Wayland socket name
for Gamescope and Weston. With inherited parent displays cleared, those
compositors perform their normal standalone backend discovery and publish the
socket names they actually chose. Gamescope presents a 640×480 game surface,
fits it to the physical output while preserving aspect ratio, and forces the
client to fill that virtual surface. Weston enables its kiosk shell and
XWayland compatibility.

When SDL12-compat is selected with Gamescope, Weston, or an existing display
manager, the installer asks whether Nucore should use native Wayland or
Xwayland. Native Wayland publishes only `WAYLAND_DISPLAY` and selects SDL2's
Wayland driver. Xwayland retains `DISPLAY` and selects SDL2's X11 driver. Native SDL 1.2 keeps
its established Xwayland path. Xorg and direct-console installations do not
offer an inapplicable Wayland/Xwayland choice. Cage is a pure Wayland kiosk in
this architecture, so its only supported path—SDL12-compat with native
Wayland—is selected automatically.

Because Nucore remains root, it must not use the login user's
`XDG_RUNTIME_DIR` directly.
Instead, the service validates the user-owned Wayland socket and exposes it
through one ephemeral symbolic link inside root's private runtime directory.
SDL2 therefore receives an ordinary relative `WAYLAND_DISPLAY` and can select
its native Wayland backend normally. Native SDL 1.2 ignores that variable and
can use Xwayland when available. Gamescope diagnostics go to the journal rather
than tty1.

SDL12-compat still has to turn Nucore's SDL 1.2 software surface into a Wayland
buffer. SDL2 has no usable Wayland software-window framebuffer for this path,
so native Wayland needs the optional 32-bit EGL/GLES2 and Mesa DRI pack for
that upload. `SDL_RENDER_DRIVER=opengles2` avoids SDL2 first selecting its
GLX-oriented OpenGL renderer; Gamescope continues to perform final scaling and
composition on the host GPU. Mesa selects its DRI driver automatically from
`bundlex86/optional/wayland-mesa-i386/dri/`. The driver names there are
symlinks to one shared Mesa binary, not duplicate copies.

The core clone intentionally excludes that approximately 208 MiB extracted
runtime because native SDL2 Wayland is experimental and Xorg/Xwayland do not
need it. The installer explains the trade-off and offers the verified 49 MiB
archive from this project's GitHub Releases only when native Wayland is
selected. It can also be managed directly:

```sh
./bin/wayland-mesa.sh install
./bin/wayland-mesa.sh status
./bin/wayland-mesa.sh remove
```

The small `sdl12_wayland_fix.so` adapter handles two legacy details at the
SDL 1.2 ABI boundary. First, Wayland requires UTF-8 window titles, while the
emulators occasionally supply an 8-bit caption that X11 accepted. Second,
Pinbox presents frames from a render worker rather than the thread that
initialized SDL. Gamescope showed a black native-Wayland surface even though
Pinbox called `SDL_Flip` at 60 Hz. The adapter coalesces those worker flips and
presents the latest completed frame when the SDL thread next polls events.
It is loaded only by SDL12-compat on Wayland; native SDL and every X11 path are
unchanged. Its auditable source is `src/sdl12_wayland_fix.c`.

Bare Xorg starts the bundled 15 KiB `nucore-wm` only for SDL12-compat. It handles
SDL2's fullscreen request without adding a desktop. Native SDL 1.2 manages its
historical X11 fullscreen path itself. The auditable source is
`src/nucore-wm.c`.

The installer resolves every package required by the selected backend through
APT: `gamescope`, `cage`, `weston`, Xwayland, or the minimal Xorg components.
Because Gamescope is Vulkan-only, a Mesa Vulkan ICD is also installed when the
host exposes no existing Vulkan implementation; vendor-provided ICDs are left
untouched.
The same resolver checks the architecture-independent ALSA configuration and
whether the distribution already provides PipeWire or PulseAudio. On a stripped
netinst with neither, it offers Debian's `pipewire-audio` set rather than
hard-coding individual service names into the launcher.
It simulates each package installation first and reports the exact packages
without candidates. On Debian stable it can check the official backports
`main` and `contrib` components after confirmation; the narrowly scoped,
project-owned source is removed on uninstall. Debian derivatives keep their
own configured repositories—the installer never injects Debian archive URLs
into another distribution. It never installs a desktop environment. It also asks for the game, watchdog, Pinbox,
SDL implementation, ASIX experiment, fullscreen mode, colour depth, maintenance
fallback, and optional quiet/zero-delay cabinet boot before showing a summary.
It can also prepend a Nucore-Portable `--config` file; the guided selections
remain cumulative and are applied afterward.

The backend can be preselected while retaining the remaining questions:

```sh
./install.sh --display-manager
./install.sh --gamescope
./install.sh --cage
./install.sh --weston
./install.sh --xorg
./install.sh --console
```

Do not install from `/tmp`: the service points to the checkout in place and a
temporary checkout can disappear at reboot. The installer warns and requires
confirmation if it detects this. To move a permanent checkout, uninstall,
move it, then reinstall.

### What changes

All choices write `/etc/systemd/system/nucore.service` and record their mode
under `/var/lib/nucore-portable/`. The display-manager path keeps
`graphical.target` and enables DM autologin without changing the user's
remembered GNOME, Plasma, X11 or Wayland session.
Standalone paths select `multi-user.target`, configure a normal PAM-backed
autologin on tty1, temporarily select `/bin/sh`, and install a tty1-only profile
hook that enters the project session host after login. They remember the
original shell and previous target/getty state. On normal game exit they can
start the installed display manager or leave a tty login for maintenance.
Administrative service stops do not trigger that fallback. A root-owned marker
under `/run` makes that password-backed maintenance login enter the recorded
original shell instead of relaunching the cabinet backend; `/run` is cleared
for the next boot.

During cabinet startup, tty1 remains the session's controlling terminal.
Standard `agetty --autologin` invokes `/bin/login`, PAM and logind directly;
there is no project login proxy. The unit journals startup output, and the
installer creates the standard empty `~/.hushlogin` when the selected user does
not already have one. Its path and inode are recorded; uninstall removes only
that unchanged project-created file. This suppresses the MOTD but does not
replace or bypass PAM. If Nucore exits to console maintenance, the temporary
maintenance getty restores visible terminal output for the normal password
prompt.

Paul's cabinet video is an excellent example of broader Linux appliance
tuning: its boot is unusually fast and the handoff into Nucore is nearly
seamless. This installer owns the Nucore launch path, not every firmware,
storage, kernel, and service optimization demonstrated there.

### Control and removal

```sh
systemctl start nucore
journalctl -u nucore -f
systemctl stop nucore
./uninstall.sh
```

`uninstall.sh` removes project-owned service and display-manager
configuration (plus obsolete polkit files from older releases), restores the
saved default target and tty1 getty state, and leaves unrelated configuration
alone. Packages accepted during a backend prompt are not automatically removed:
they may have become dependencies of other software.
It also removes Nucore-Portable's separate GRUB drop-in, when present, and
regenerates GRUB without modifying the distribution's theme or the user's
original `/etc/default/grub` settings.
While the zero-second cabinet setting is installed, the drop-in disables the
GRUB theme and graphical background as well: otherwise GRUB can flash the
distro theme for a few milliseconds while initializing it, despite having no
menu delay. Shift/Escape recovery remains available through GRUB's plain text
menu. For a normal quiet boot, a project-owned GRUB generator also makes
ordinary terminal text black-on-black, hiding Debian's unconditional “Loading
Linux” and “Loading initial ramdisk” lines. Menu entries use separate colours,
and the rule is disabled automatically after `recordfail`, so recovery and
failed-boot diagnostics remain visible. Uninstall removes both project files
and exposes the distribution presentation again unchanged.
When uninstalling from a live desktop, an already active display manager keeps
the visible VT; getty is re-enabled for future boots without stealing tty1.

## Cabinet I/O and compatibility experiments

* **LPT (parallel port)**: `./start.sh swe1_14 -parallel 0x378`
* **ASIX `.so.6` compatibility experiment**: `./start.sh --asix --no-reboot swe1_14`

### Nucore function keys

These are Nucore controls, not launcher shortcuts:

| Function key | Additional legacy binding | Function |
|---|---|---|
| `F1` | `,` | Exit Nucore; cabinet integration then opens its chosen maintenance fallback |
| `F2` | `.` | Toggle the screen upside down, useful while servicing the display |
| `F3` | `/` | Decrease GI/light timing by one fine step |
| `F4` | Right Shift | Increase GI/light timing by one fine step |
| `F5` | Keypad `*` | Decrease GI/light timing by one coarse step |
| `F6` | Left Alt | Increase GI/light timing by one coarse step |

These aliases were recovered from the binary's special-key switch: PC
scancodes `0x33`–`0x38` mirror F1–F6 at `0x3b`–`0x40`. The displayed symbol
for the punctuation positions can vary with keyboard layout; the function keys
are the clearest bindings for normal use.

The F3–F6 adjustments compensate for GI-light flicker caused by timing
differences between PCs. Nucore saves the selected timing. The playfield relay
may click while it is being adjusted; the original manual says this is
expected.

That save is broader than the timing value: F3–F6 make Nucore rewrite the
whole current `pb2k.cfg`. Consequently, temporary command-line overrides such
as `-window`, `-fullscreen`, `-flipscreen` or `-bpp 32` can become persistent
if F3–F6 are pressed during that run. F2 alone toggles inversion only in memory;
pressing F3–F6 afterward can include the resulting inversion in the full-file
save. A normal Nucore exit does **not** write `pb2k.cfg`; it saves game state
(NVRAM, flash, SEE and EMS) separately.

Pinbox differs here: testing confirms that it writes its current configuration
back as part of its run/exit behavior, so a config-backed command-line choice
can persist without an F3–F6 timing adjustment. Do not assume a Nucore and a
Pinbox test leave `pb2k.cfg` in the same state. No Nucore functions are
documented for F7–F12.

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

Nucore selects the update tree for the running game. It expects these
exact paths:

```text
update/swe1_14/swe1_14_update.bin
update/rfm_15/rfm_15_update.bin
```

The SWE1 and RFM trees can coexist. Only one firmware payload belongs
inside each game directory, however: do not mix files from two versions
of the same game. To install a community bundle:

1. Remove and recreate **only the target game's directory**. For SWE1:
   ```sh
   rm -rf -- update/swe1_14
   mkdir -- update/swe1_14
   ```
   For RFM, use `update/rfm_15` instead.
2. Open the community archive and find the directory containing the
   matching `*_update.bin`, `gamelist.txt`, and `pin2000_*` files.
   Extract those files directly into `update/swe1_14/` or
   `update/rfm_15/` — flat inside that game directory, with no extra
   archive directory around them.
3. Check that the payload has the exact name Nucore expects
   (`swe1_14_update.bin` or `rfm_15_update.bin`), then launch normally.
   The boot screen should report the community firmware version.

To restore the official Williams payload for one game, replace only
that directory from Git. For example, for SWE1:

```sh
rm -rf -- update/swe1_14
git restore --source=HEAD -- update/swe1_14
```

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

# SDL12-compat display path (requires a matching live display)
./start.sh --no-reboot --sdl12-compat --wayland swe1_14
./start.sh --no-reboot --sdl12-compat --xwayland swe1_14

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
| `--no-runner` | off | Launch the no-watchdog emulator binary directly, without runner setup or crash handling; diagnostic only |
| `--pinbox` | off | Run the Pinbox fork instead of Nucore |
| `--asix` | off | **Experimental:** select the newer ASIX `libftchipid` path that uses `libstdc++.so.6` instead of the original `.so.5` |
| `--sdl12-compat` | off | **Experimental:** translate SDL 1.2 calls to bundled SDL 2 |
| `--wayland` | auto | With SDL12-compat, require SDL2 native Wayland and apply its bundled GLES2 compatibility defaults |
| `--xwayland` | auto | With SDL12-compat, require SDL2's X11 driver through the available Xwayland server |
| `--console` | off | **Advanced:** permit SDL direct display after refusing active graphical sessions; native SDL may choose fbcon and SDL2 may choose KMSDRM |
| `--no-shim` | off | **Experimental:** do not preload `sigio_fix.so` |
| `--no-audio-shim` | off | Keep RTC/SIGIO protection but disable the shim's mixer-buffer and realtime-scheduling changes |
| `--no-sigio-shim` | off | Disable RTC/SIGIO protection while leaving the selected mode's audio behavior unchanged; diagnostic only |
| `--config FILE` | none | Prepend a saved Nucore-Portable command line containing `--` launcher options, a game and/or `-` Nucore options |
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
`-nojukeplay`. The launcher prepends only the project default `-nowatermark`;
all supplied Nucore options follow it unchanged.

### Games

| Name | Game |
|---|---|
| `swe1_14` or `swe1` | Star Wars Episode 1 — Revision 1.4 *(default)* |
| `rfm_15` or `rfm` | Revenge From Mars — Revision 1.5 |
| `auto` | Ask Nucore to detect the game |

### Two different kinds of configuration

Nucore automatically reads the fixed file `config/pb2k.cfg` when it starts.
Edit that file directly for persistent Nucore settings:

```sh
nano config/pb2k.cfg
./start.sh --no-reboot swe1_14
```

It controls Nucore values such as gamma, fullscreen, screen inversion, renderer
depth, watermark, jukebox/playlist behavior, USB, tournament/server settings,
server ports and tick adjustment. Portable-specific choices such as
`--no-reboot`, `--asix`, `--sdl12-compat` and shim selection remain launcher
options.

The bundled Nucore binaries correct the original initialization order, so
explicit video arguments reliably override the loaded configuration for one
launch:

```sh
./start.sh --no-reboot swe1_14 -window
./start.sh --no-reboot swe1_14 -fullscreen
```

These arguments do not edit `pb2k.cfg`. When both are present, the last one
wins for that process. A later launch without either argument returns to the
persistent `FULL_SCREEN` value in the file.

This describes launcher startup and a normal Nucore exit. Nucore's F3–F6
timing controls deliberately save the entire current configuration, which can
also capture active CLI video overrides. Pinbox has a different persistence
path and writes its current configuration during its run/exit lifecycle. See
the [function-key notes](#nucore-function-keys) before doing presentation tests
against a cabinet configuration you want to preserve.

The shipped `pb2k.cfg` supplies the normal fullscreen and 16-bpp defaults.
Nucore-Portable additionally enforces `-nowatermark` on every launch. Nucore
has no opposite command-line switch, so changing `WATERMARK=1` in `pb2k.cfg`
does not re-enable it through this launcher; this is the one deliberate
Portable presentation policy.

Separately, `--config FILE` belongs to **Nucore-Portable**. It reloads a saved
launcher command line; it is never passed to Nucore as a `.cfg` argument. Copy
the example and put launcher options (`--...`), the game, and Nucore options
(`-...`) in it:

```sh
cp config/nucore-portable.conf.example config/cabinet.conf
nano config/cabinet.conf
./start.sh --config config/cabinet.conf
```

For example, the file can contain:

```text
--asix --sdl12-compat
swe1_14
-fullscreen -bpp 16 -parallel 0x378
```

Whitespace and shell-style quotes delimit arguments; blank lines and full-line
`#` comments are ignored. Nothing is evaluated as shell code: `$HOME`, command
substitutions and redirections remain ordinary argument text. Keep the normal
command order: Portable `--options` first, then the game, then Nucore
`-options`. Words supplied
after `--config FILE` are appended, which is useful when the saved file omits
the game or when adding another independent Nucore option. Do not specify two
games: the first positional game ends launcher parsing and the second would be
passed to Nucore as an extra argument.

When `install.sh` is given a Portable config, that complete saved command line
is authoritative for the service, so the installer skips its separate game and
Pinbox prompts.

### Nucore command-line reference recovered from the binary

For the reproducible low-level methods behind this recovery—live `argv`
inspection, string and disassembly work, loader tracing, and GDB breakpoints on
SDL boundaries—see [Nucore binary archaeology](BINARY-ARCHAEOLOGY.md). It also
records what is proven, and what remains an inference, about the current
`-window` investigation.

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
last one wins for that launch. The patched bundled Nucore executables load
`pb2k.cfg` first and apply command-line values afterward; `start.sh` does not
rewrite the file.

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

Nucore-Portable passes independent switches such as `-nojukeplay`,
`-flipscreen`, `-nopause` and `-bpp 32` through in their original order after
its sole implicit Nucore argument, `-nowatermark`; they apply only to that
invocation. The same temporary behavior now applies to `-window`,
`-fullscreen`, `-flipscreen` and `-bpp`: they override the persistent values
loaded from `pb2k.cfg` without editing it.

#### Low-level positional forms and legacy entries

The binary itself accepts `?`, `-h` or `--h` as its first argument to print
its small embedded help screen. `start.sh` handles `-h` and `--help` as
launcher help instead.

The binary also has a separate positional `.cfg` mechanism that prints
`Using config file: ...`, but it does **not** parse `pb2k.cfg` settings there.
Passing `pb2k.cfg` through that mechanism makes each `KEY=value` line get
treated like a game-name input. Nucore-Portable deliberately does not expose
this unrelated and undocumented mechanism as a launcher option.

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

> **A useful preservation pattern.** Nucore's emulation logic and old API
> expectations stay untouched apart from one documented initialization-order
> correction in the two bundled Nucore executables. Most modernization remains
> at the boundaries—an ELF loader for
> current x86_64 hosts, SDL12-compat over SDL 2, ALSA plugins reaching
> PulseAudio/PipeWire, an ASIX library using `libstdc++.so.6`, and small shims
> for legacy signal/audio behavior. The old program continues to see the world
> it expects while each adapter speaks to a newer Linux layer. The same approach
> can preserve other closed-source or abandoned programs: identify one obsolete
> boundary, place a reversible compatibility layer there, and A/B test it
> without rewriting the program's internals.

“Modern” is relative to Nucore, not shorthand for “latest.” The original
Nucore package is from 2018 and includes still older dependencies (the bundled
FTDI D2XX library is approximately 2010). The optional ASIX `libftchipid` 0.1.0
experiment is from 2011. At the newest end, the SDL bridge is Debian 13's
`sdl12-compat` 1.2.68-3 running over bundled SDL 2.32.4. Thus the alternatives
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
INFO: sdl12-compat 1.2.68, ... SDL2 2.26.5     # core X11/Xwayland path
INFO: sdl12-compat 1.2.68, ... SDL2 2.32.4     # optional native-Wayland pack
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

After `./install.sh`, the root system unit already has the required privilege.
It attaches to the runtime/display environment published by a real PAM/logind
user session; that user never launches or elevates Nucore.

### Interactive visual matrix

The maintainer matrix runs every supported Pinbox display combination for up
to 40 seconds, then records an OK/KO rating and an optional comment:

```sh
# Standalone cabinet paths from a TTY
./test-matrix.sh
./test-matrix.sh --only:gamescope-sdl2-wayland

# Nested paths inside the currently running desktop
./test-matrix.sh --desktop
./test-matrix.sh --desktop --only:display-manager-sdl2-wayland

# Diagnostic: run SDL2 without the bundled 32-bit Mesa DRI stack
./test-matrix.sh --no-bundled-mesa --only:gamescope-sdl2-wayland
```

Desktop mode leaves the active display manager and VT alone. Gamescope, Cage,
and Weston run nested in the current graphical session; display-manager cases
attach directly to that live session. Bare Xorg and direct-console cases remain
TTY-only because they need ownership of a VT/display device. Results and per-run
logs are retained under `/tmp/nucore-visual-matrix.*/`. The matrix also works
from an uninstalled checkout: it creates a minimal non-enabled service and
configuration for the duration of the test, then removes them on exit.

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
* `test-matrix.sh` for guided TTY or nested-desktop backend validation
* `install.sh` for production: a reversible session-oriented systemd
  integration with display-manager, Gamescope, Cage, Weston, Xorg and direct
  console choices. It never installs a desktop environment.

`nucore` itself is the upstream Big Guy's Pinball 2.25.3R build extracted from
the official Lubuntu deb in FlipperFiles. Its emulator internals are unchanged;
the bundled copy carries only the documented configuration/CLI initialization
order patch described in [Nucore binary archaeology](BINARY-ARCHAEOLOGY.md).

## What's in the box

```
bin/                  binaries + launcher
  bundled.sh          re-exec wrapper around the bundled ld-linux
  wayland-mesa.sh     optional Mesa i386 pack manager
  nucore-service.sh   privileged service side of the session broker
  nucore-session.sh   unprivileged selected-backend host
  sigio_fix.so        LD_PRELOAD shim — fixes audio + signals on x86_64
  sdl12_wayland_fix.so  SDL12-compat native-Wayland presentation adapter
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
  sdl12_wayland_fix.c native-Wayland adapter source
  Makefile            builds both adapters in ../bin/
test-matrix.sh        guided Pinbox backend matrix (TTY or desktop-hosted)
bundlex86/            i386 shared libraries the bundle ships
  direct/             libs nucore links against directly
  indirect/           transitive deps + ld-linux.so.2
  alsa-lib/           32-bit Pulse ALSA plugin set
  asix/               complete ASIX libftchipid 0.1.0 / libstdc++.so.6 overlay
  sdl12-compat/       opt-in SDL 1.2 ABI → SDL 2 translation overlay
  optional/           downloaded add-ons, absent from the core clone
    wayland-mesa-i386/  native-Wayland EGL/GLES2 + Mesa DRI runtime
roms/                 ROMs + savedata (.nvram, .flash, .ems, .see)
update/               per-game update trees; both may coexist
  swe1_14/            SWE1 update tree (latest official Williams: 0150)
  rfm_15/             RFM  update tree (latest official Williams: 0180)
                      Newer post-Williams firmware (Jim Askey at
                      mypinballs.com) is supported at runtime — see
                      the "Community updates" section below — but is
                      not redistributed here.
resources/            UI overlays, jukebox, watermark, load screens
config/               Nucore's leds.cfg, pb2k.cfg and servers.txt, plus the
                      Nucore-Portable command-line config example
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

`start.sh` first safely tokenizes an optional Nucore-Portable command-line
config, prepends those saved words to the explicit command line, then parses
its runner, SDL, shim, privilege and inhibitor options. It
picks a `(runner, binary)` pair and calls
`bin/bundled.sh <mode> bin/<runner> bin/<binary> <game> <args>`. Nucore reads
its own fixed `../config/pb2k.cfg`; explicit arguments remain last so they can
override its values. The runner
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
* The bundled `nucore` and `nucore_nwd` contain the documented 20-byte
  configuration/CLI initialization-order patch described in
  [Nucore binary archaeology](BINARY-ARCHAEOLOGY.md). Their original and
  patched checksums are recorded there.

## Privileges (no more `sudo run nucore`)

The original cabinet command was `sudo run nucore swe1_14`. On stock
Debian 13 the user is no longer in the sudoers file — `sudo` says "user
not in sudoers" and refuses. nucore-portable handles this transparently:

* **Dev / desktop launches (`./start.sh`)** auto-detect the escalation
  tool, in order: nothing-needed (caps already inherited from a parent
  unit) → `run0` (systemd ≥256 plus `polkitd`/`pkttyagent`: pops a proper
  polkit authentication dialog, no sudoers required) → `pkexec` (older
  polkit) → `sudo`
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
* **Installed sessions (`./install.sh`)** keep the emulator in a uid-0 system
  service while a normal PAM/logind login supplies runtime, audio and display
  services. Display-manager mode obtains that login from GDM/SDDM/LightDM;
  standalone backends obtain it through agetty and `/bin/login`. No polkit or
  administrator rights are granted to the session user.

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

* `bin/nucore` — extracted from
  `FlipperFiles/Files/Lubuntu_packages/nucore-2.25.3r-package-v003-wahcade.deb`,
  then patched for configuration-before-CLI initialization order
* `bin/nucore_nwd` — watchdog-neutralised testing variant carrying the same
  initialization-order patch
* `bin/{nucore.225, nucore.old, run, n_update, n_update.old}` — extracted from
  the same upstream Nucore package
* `bin/{runrd, run_pb_rd, pinbox_nwd, sigio_fix.so,
  sdl12_wayland_fix.so}` — local testing/support builds
* `bin/pinbox` — the pinbox fork of nucore
* `bundlex86/` — pre-curated i386 system libraries (libc, libSDL, libmpg123,
  libasound, ld-linux.so.2, etc.) collected from Debian/Ubuntu i386 packages
* `bundlex86/alsa-lib/` — Debian i386 Pulse ALSA configuration, PCM and control
  plugins used to avoid host multiarch dependencies
* `bundlex86/sdl12-compat/` — Debian 13 i386 `sdl12-compat` 1.2.68-3;
  checksum and full redistribution notices are included beside the binary
* optional `bundlex86/optional/wayland-mesa-i386/` — the verified
  `wayland-mesa-i386-v2` GitHub Release asset, downloaded only for native
  SDL2 Wayland; it includes SDL2 2.32.4 plus the EGL/GLES2/Mesa renderer, and
  its DRI driver aliases share one Mesa binary
* `bundlex86/asix/libftchipid.so.0` — official ASIX i386 `libftchipid` 0.1.0;
  source URL, naming details and SHA-256 checksums are recorded in the adjacent
  `README.md`
* `roms/`, `update/` — extracted from `FlipperFiles/Roms/Nucore/nucore-roms.tar.gz.*`
* `resources/`, `config/`, `install/` — from the same upstream nucore deb
```
