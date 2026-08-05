# ASIX libftchipid 0.1.0 overlay

This opt-in i386 overlay recreates the tested ASIX compatibility experiment:

- `libftchipid.so.0` is ASIX `libftchipid.so.0.1.0`, renamed to the filename
  requested by Nucore. Its internal SONAME remains `libftchipid.so`.
- It depends on `libstdc++.so.6` instead of Nucore's original
  `libftchipid.so.0`, which depends on the obsolete `libstdc++.so.5`.
- It requests `libftd2xx.so`; the matching filename is included in this
  overlay. The original Nucore binary also requests `libftd2xx.so.0`.
- `libltdl.so.3` is the companion library retained from the successful
  historical experiment.

Official source:
https://asix.tech/_usb/ftdi_linux/libftchipid.0.1.0.tar.gz

The official download is a POSIX tar archive despite its `.tar.gz` suffix;
extract it with `tar -xf`, not `tar -xzf`.

SHA-256:

```text
official archive:
690e94aab3b69e7f11cd10af96e62d239f0e393b5869bb189511ddedf6e27868

build/i386/libftchipid.so.0.1.0 (bundled as libftchipid.so.0):
df00c150f3820c3f36d6d5d8680bbd48a09f01bb697d915856b71484f5d6b115
```

Select it with:

```sh
./start.sh --asix --no-reboot swe1_14 -window
```

Without `--asix`, Nucore continues to use its original `libftchipid` and
`libstdc++.so.5` path.
