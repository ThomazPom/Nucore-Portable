# Debian netinst regression VM

This laboratory creates a genuinely minimal Debian 13 guest once, keeps that
post-install disk immutable, and runs every Nucore Portable experiment in a
fresh qcow2 overlay.

By default the guest opens a GTK window backed by an 800x600 virtual display,
so fullscreen placement and scaling can be inspected. Set
`NUCORE_QEMU_HEADLESS=1` only for unattended or CI runs.

The base guest intentionally has no desktop, `sudo`, `pkexec`, `polkitd`, Xorg
or Wayland compositor. It includes only enough infrastructure for automated
testing: OpenSSH, Git, CA certificates and `qemu-guest-agent`. The host harness
needs `qemu-system-x86`, `qemu-system-gui`, `qemu-utils`, `curl`, `cpio`,
`sshpass` and `expect`.

Useful commands:

```sh
./tools/debian-qemu/lab.sh prepare       # netinstall and seal the base image
./tools/debian-qemu/lab.sh test xorg     # fresh overlay; test ./install.sh --xorg
./tools/debian-qemu/lab.sh test console  # fresh overlay; test direct console
./tools/debian-qemu/lab.sh test kmsdrm   # fresh overlay; test SDL2 direct DRM/KMS
./tools/debian-qemu/lab.sh manual        # start/resume the current graphical VM
./tools/debian-qemu/lab.sh shell         # SSH into the current overlay
./tools/debian-qemu/lab.sh stop
./tools/debian-qemu/lab.sh reset         # fresh overlay; next manual injects current checkout
```

The lab's deliberately simple virtual VGA is sufficient for session, Xorg and
direct-console lifecycle tests. Gamescope requires a Vulkan implementation,
which this portable QEMU configuration does not pretend to provide. If it
rejects the virtual GPU,
the cabinet failure fallback should present a maintenance login instead of
leaving the last GRUB frame on screen. Validate Gamescope rendering and scaling
on physical Vulkan-capable hardware.

Artifacts live outside Git under `${XDG_CACHE_HOME:-~/.cache}/nucore-qemu` by
default. Set `NUCORE_QEMU_DIR`, `NUCORE_QEMU_CPUS`, or `NUCORE_QEMU_RAM` to
override the location and VM size. The base image is never booted by a test;
`current.qcow2` is always a disposable backing-file overlay.

The netinstall inherits the host's `LANG`, keyboard layout and keyboard
variant. Different locale/keymap combinations receive different sealed base
images, so switching between AZERTY and QWERTY never mutates an existing base.
They can also be selected explicitly with `NUCORE_QEMU_LOCALE`,
`NUCORE_QEMU_KEYBOARD` and `NUCORE_QEMU_KEYBOARD_VARIANT`.

The automated test first proves that the stock guest has `run0`, but no
`pkttyagent`, `pkexec`, `polkitd` or `sudo`. It then installs only `polkitd` in
the disposable overlay and launches `./install.sh` as the unprivileged
`cabinet` user. This exercises the corrected `run0`/`pkttyagent` path instead
of bypassing it as root. It validates installation state and uninstall
symmetry before discarding the VM.

`reset` creates an overlay from the sealed end-of-netinstall snapshot and marks
it for one checkout injection. The next `manual` copies the current host
worktree to `~/Nucore-Portable`, verifies that copy, adds only `polkitd` for the
non-root `run0` test, and opens the graphical console. Later `manual` boots
preserve that overlay and its guest worktree exactly; they never copy the host
checkout again. Both the test user and root use the laboratory-only password
`cabinet`.
