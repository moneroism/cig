# cig

A minimal, hardened Linux distribution built from source, in the spirit of
GrapheneOS but for the PC: as little code as possible, every component
verified, nothing running that isn't needed.

> **Status:** work in progress. Boots in QEMU (UEFI), has networking and
> verified TLS. Added a graphical session. Not for daily use YET.

## Design

| Area | Choice | Why |
|---|---|---|
| Kernel | [linux-hardened](https://github.com/anthraxx/linux-hardened) 6.18 LTS | Mainline + hardening patches, stripped to the hardware actually used |
| C library | musl | ~10x less code than glibc |
| Userland | BusyBox (trimmed) | One binary, no network daemons, no setuid |
| Init | sinit (PID 1, ~100 lines) + BusyBox runit (supervision) | Minimal PID 1; supervisor runs as an ordinary process |
| Boot | EFISTUB, no bootloader | Zero bootloader code; command line is compiled in and cannot be changed at boot |
| TLS | OpenSSL 3.5 LTS | Compatibility; pinned to the LTS branch |
| Desktop | Wayland: dwl, foot, wmenu (optional) | Upstream defaults, no theming. No X11; D-Bus only if Bluetooth is selected |

### Hardening

- Kernel modules must be signed; the signing key is deleted after the build,
  so no new module can ever be signed for an installed kernel.
- Kernel lockdown (integrity mode); optional runtime lock of module loading.
- Built-in kernel command line: `slab_nomerge`, `init_on_alloc`, `init_on_free`,
  `page_alloc.shuffle`, `randomize_kstack_offset`, `vsyscall=none`, `debugfs=off`.
- sysctl: restricted kernel pointers and dmesg, ptrace scope 2, no unprivileged
  BPF or user namespaces, no kexec, IPv6 privacy addresses.
- Everything compiled with PIE and stack protector by default.
- `/tmp` in RAM with `noexec`; `/home` with `nosuid,nodev`; the ESP is not
  mounted during normal use.
- No microcode is shipped. Only two firmware files sets are installed
  (Intel 7265 WiFi, AMD Polaris GPU), with checksums.
- curl is built with HTTP(S) and FILE only; wpa_supplicant with WPA2/WPA3-Personal
  only (no WPS, no EAP, no D-Bus), with MAC randomization.

### Supply chain

Every source tarball is verified by GPG signature before use. Where upstream
publishes no signature (perl, the CA bundle, libnl), this is stated openly
and checksums are recorded. Signer fingerprints, versions and SHA256 sums of
the current build are in [`record/`](record/).

## Build

Host: Void Linux (x86_64). The build is split into phases; each script is
safe to re-run and skips finished steps. All scripts are in [`scripts/`](scripts/)
and are run as `~/cig/scripts/<name>`.

| # | Script | Where | What |
|---|---|---|---|
| 0 | `fetch-sources.sh` | host | Get linux-hardened and linux-firmware at the versions pinned in `record/` |
| 1 | `build-toolchain.sh` | Void | musl cross-toolchain (binutils, gcc, musl) |
| 2 | `build-temp.sh` | Void | Temporary system (BusyBox, bash, make, gawk, native gcc) |
| 3 | `enter-chroot.sh` | Void (sudo) | Enter the new system |
| 4 | `prepare-base.sh` → `build-base.sh` | Void → chroot | Final toolchain, trimmed BusyBox, sinit, init config |
| 5 | `install-boot.sh` | Void | Kernel with built-in cmdline, modules, firmware, os-release |
| 6 | `run-vm.sh` | Void | Boot the image in QEMU with UEFI |
| 7 | `prepare-essentials.sh` → `build-essentials.sh` | Void → chroot | zlib, e2fsprogs, OpenSSL, curl, git, wpa_supplicant, networking |
| 8 | `prepare-buildtools.sh` → `build-buildtools.sh` | Void → chroot | pkgconf, samurai, Python 3.13, meson, service logging |
| 9 | `prepare-wayland.sh` → `build-wayland.sh` | Void → chroot | Wayland core: libinput stack, seatd, wlroots 0.19 (CPU rendering, no Xwayland) |
| 10 | `prepare-desktop.sh` → `build-desktop.sh` | Void → chroot | fonts (JetBrains Mono), foot, dwl 0.8, session (`startdwl`) |
| 11 | `prepare-admin.sh` → `build-admin.sh` | Void → chroot | doas for `wheel`, upstream default configs |

Expected layout:

```
~/cig/                this repository
~/cig/scripts/        build scripts
~/cig/linux-hardened  kernel source, tag v6.18.54-hardened1 (not committed)
~/cig/linux-firmware  firmware source (not committed)
~/lfs.img           disk image (not committed)
```

The kernel configuration is in [`kernel/`](kernel/).

## Pinned versions and why

| Package | Pin | Reason |
|---|---|---|
| gawk | 5.3.2 | gawk 5.4.x makes GCC 16's option generator produce broken output |
| git | 2.x, `NO_RUST=1` | git 2.54+ builds Rust by default; git 3.0 makes Rust mandatory |
| BusyBox | 1.36.1 | Latest release marked stable |
| GNU make, flex | built as C17 | Pre-C23 code; GCC 15+ defaults to C23 |
| Python | 3.13.x | Last series with GPG-signed releases (3.14+ uses Sigstore only); build tool only |
| ninja | samurai | Same job in C, ~4k lines, instead of C++ |

## Roadmap

- [x] Build tools: meson, samurai, pkgconf, Python; service logging via svlogd
- [x] Wayland stack with CPU rendering (pixman), dwl, foot, wmenu
- [ ] Bare hardware: RX570, Intel 7265 WiFi, SATA SSD
- [ ] App manager: git + JSON, optional on-device compile with SHA256 verification
- [ ] Mesa / GPU acceleration (decision on LLVM)
- [ ] hardened_malloc, sandboxing, read-only root
- [x] doas for admin tasks (`doas poweroff`)
- [ ] Generic kernel, package split, install media, shell TUI installer with hardware detection
- [ ] Optional components: PipeWire, Bluetooth (BlueZ + D-Bus), wmenu
- [ ] `sudo` compatibility command that calls doas

## License

```
cig - a minimal, hardened GNU/Linux distribution.
Copyright (C) 2026 moneroism

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program.  If not, see https://www.gnu.org/licenses/.
```

The full license text is in [`LICENSE`](LICENSE).
