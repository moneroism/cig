## LICENSE NOTICE
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

> **Status:** work in progress. Boots in QEMU (UEFI), has networking and
> verified TLS. No graphical session yet. Not for daily use.

## Design

| Area | Choice | Why |
|---|---|---|
| Kernel | [linux-hardened](https://github.com/anthraxx/linux-hardened) 6.18 LTS | Mainline + hardening patches, stripped to the hardware actually used |
| C library | musl | ~10x less code than glibc |
| Userland | BusyBox (trimmed) | One binary, no network daemons, no setuid |
| Init | sinit (PID 1, ~100 lines) + BusyBox runit (supervision) | Minimal PID 1; supervisor runs as an ordinary process |
| Boot | EFISTUB, no bootloader | Zero bootloader code; command line is compiled in and cannot be changed at boot |
| TLS | OpenSSL 3.5 LTS | Compatibility; pinned to the LTS branch |
| Planned desktop | Wayland: dwl, foot, wmenu | No X11, no D-Bus, no systemd |

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
safe to re-run and skips finished steps.

| # | Script | Where | What |
|---|---|---|---|
| 1 | `build-toolchain.sh` | Void | musl cross-toolchain (binutils, gcc, musl) |
| 2 | `build-temp.sh` | Void | Temporary system (BusyBox, bash, make, gawk, native gcc) |
| 3 | `enter-chroot.sh` | Void (sudo) | Enter the new system |
| 4 | `prepare-base.sh` → `build-base.sh` | Void → chroot | Final toolchain, trimmed BusyBox, sinit, init config |
| 5 | `install-boot.sh` | Void | Kernel with built-in cmdline, modules, firmware, os-release |
| 6 | `run-vm.sh` | Void | Boot the image in QEMU with UEFI |
| 7 | `prepare-essentials.sh` → `build-essentials.sh` | Void → chroot | zlib, e2fsprogs, OpenSSL, curl, git, wpa_supplicant, networking |

`fix-busybox.sh` repairs BusyBox from the host if its links ever get broken.

Expected layout:

```
~/cig/              this repository
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

## Roadmap

- [ ] Build tools: meson (or muon), ninja, pkgconf; service logging via svlogd
- [ ] Wayland stack with CPU rendering (pixman), dwl, foot, wmenu
- [ ] Bare hardware: RX570, Intel 7265 WiFi, SATA SSD
- [ ] App manager: git + JSON, optional on-device compile with SHA256 verification
- [ ] Mesa / GPU acceleration (decision on LLVM)
- [ ] hardened_malloc, sandboxing, read-only root
- [ ] Minimal power helper so a normal user can power off
