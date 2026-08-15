# Debian netinst regression VM

This laboratory creates a genuinely minimal Debian 13 guest once, keeps that
post-install disk immutable, and runs every Nucore Portable experiment in a
fresh qcow2 overlay.

```sh
./tools/debian-qemu/lab.sh all
```

The base guest intentionally has no desktop, `sudo`, `pkexec`, `polkitd`, Xorg
or Wayland compositor. It includes only enough infrastructure for automated
testing: OpenSSH, Git, CA certificates and `qemu-guest-agent`. The host harness
needs `qemu-system-x86`, `qemu-utils`, `curl`, `cpio` and `sshpass`.

Useful commands:

```sh
./tools/debian-qemu/lab.sh prepare       # netinstall and seal the base image
./tools/debian-qemu/lab.sh test xorg     # fresh overlay; test ./install.sh --xorg
./tools/debian-qemu/lab.sh test console  # fresh overlay; test direct console
./tools/debian-qemu/lab.sh shell         # SSH into the current overlay
./tools/debian-qemu/lab.sh stop
./tools/debian-qemu/lab.sh reset         # discard only the current overlay
```

Artifacts live outside Git under `${XDG_CACHE_HOME:-~/.cache}/nucore-qemu` by
default. Set `NUCORE_QEMU_DIR`, `NUCORE_QEMU_CPUS`, or `NUCORE_QEMU_RAM` to
override the location and VM size. The base image is never booted by a test;
`current.qcow2` is always a disposable backing-file overlay.

The test command validates installation state and then runs the uninstaller.
Graphics cannot be visually certified through this headless harness, but the
package discovery, prompts, systemd units, configuration, boot-target changes
and uninstall symmetry are exercised on the stripped system.
