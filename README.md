# cig

A minimal, hardened GNU/Linux distribution built from source, in the spirit
of GrapheneOS but for the PC: as little code as possible, every source
verified, nothing running that isn't needed, and nothing hardcoded to one
machine.

> **Status:** 0.2.1 (beta), on the way to 0.3.0. A bootable install medium (USB image)
> runs a live system, and its installer installs a system that boots on its own with
> its own linux-hardened kernel, signed modules and lockdown, and a Wayland desktop
> (dwl + foot, or sway): tested in QEMU (UEFI). smoke and the installer are C; everything
> is built from recipes with `cigbuild`, and every source's authenticity is audited
> ([`docs/sources.md`](docs/sources.md)). Mesa without LLVM (RADV + Zink) is built for AMD
> GPUs but not yet tested on the hardware. Next: the first install on real hardware, a
> kernel with all drivers for the medium. Not for daily use. See [`ROADMAP.md`](ROADMAP.md).

## Principles

- **Minimal attack surface.** Small implementations are preferred (musl,
  BusyBox, sinit, samurai); features nobody uses are compiled out.
- **Every source verified.** Recipes pin a SHA256; `cigbuild pin` checks the
  upstream GPG signature before a checksum is pinned. Sources without an
  upstream signature are marked as trust-on-first-use, openly.
- **Compiled on the machine.** The kernel is configured for the hardware it
  runs on, with a module signing key that is generated during the build and
  deleted afterwards, so every installation has its own key.
- **Nothing hardcoded.** Hardware-dependent choices (GPU drivers, kernel
  drivers, firmware) are detected or chosen, never fixed to one machine.
  Every optional component can be deselected.
- **Upstream defaults.** No theming; users configure their own system.
- **Auditable.** One readable inventory says what is installed and why;
  `smoke audit` checks the whole system against it.

## Design

| Area | Choice |
|---|---|
| Kernel | [linux-hardened](https://github.com/anthraxx/linux-hardened) 6.18 LTS, configured per machine |
| C library | musl |
| Userland | BusyBox (trimmed: no network daemons, no `su`, no setuid, no BusyBox TLS) |
| Init | sinit (PID 1, ~100 lines) + BusyBox runit applets for supervision |
| Devices | devtmpfs + BusyBox mdev, libudev-zero, seatd (no udev, no logind) |
| Boot | EFISTUB, no bootloader; the command line is compiled in |
| Admin | doas, for members of `wheel` (the only setuid program) |
| Packages | `cigbuild` builds, `smoke` installs: every package in its own folder under `/usr/pkg` |
| TLS | OpenSSL 3.5 LTS |
| Desktop | Wayland: dwl, foot; CPU rendering (pixman) for now. No X11. |
| D-Bus | none (planned only as a dependency of optional Bluetooth) |

### Hardening

- Module signing enforced; the private key is deleted after the build.
- Kernel lockdown (integrity); optional runtime lock of module loading
  (`/etc/lock-modules`).
- GCC hardening plugins of linux-hardened (latent_entropy, stackleak, randstruct).
- Built-in command line: `slab_nomerge`, `init_on_alloc`, `init_on_free`,
  `page_alloc.shuffle`, `randomize_kstack_offset`, `vsyscall=none`, `debugfs=off`.
- sysctl: restricted kernel pointers and dmesg, ptrace scope 2, no unprivileged
  BPF or user namespaces, no kexec, no SysRq, IPv6 privacy addresses
  (`/etc/sysctl.conf`, additions in `/etc/sysctl.d/`).
- Everything compiled with PIE and stack protector by default; full RELRO.
- `/tmp` in RAM with `noexec`; `/home` with `nosuid,nodev`; the EFI partition
  is not mounted during normal use.
- No CPU microcode is ever shipped. Firmware: only the files the machine's
  drivers request.
- curl: HTTP(S) and FILE only. wpa_supplicant: WPA2/WPA3-Personal only (no WPS,
  EAP or D-Bus), MAC randomization.

## Repository

```
cigbuild            build tool: recipe -> verified source -> package (shell, as recipes are)
lib/                cigbuild's shared code (recipes, build styles, hardware detection)
src/smoke/          smoke, the package manager (C; package cig-tools)
src/installer/      cig-install, the installer (C, ncurses; package cig-installer, media only);
                    test/run.sh checks the partition logic against reference results
src/pixel/          pixel, terminal animations (C; package pixel)
packages/<name>/    one recipe per package (+ files/ for extra files)
assets/             logos and banners (ASCII and braille), with their size and colour rules
scripts/            bootstrap, the install media (build-media.sh) and VM helpers
VERSION             the cig release (X.0.0 stable, 0.X.0 beta, x.y.Z fixes)
docs/               design documents: smoke, sources (how every source is authenticated)
kernel/             earlier kernel configs (reference)
ROADMAP.md          goals and phases
```

## cigbuild

Builds packages. Runs inside cig itself (chroot, installer, installed
system); needs only bash, curl and BusyBox. Pinning with signature checks
needs gpg, so it is done on the host.

```
cigbuild build   <pkg>...   fetch + verify + build a package (dependencies via smoke)
cigbuild install <pkg>...   same as: smoke add -c -y
cigbuild rebuild <pkg>...   build again from source; smoke switches to the new build
cigbuild pin     <pkg>...   verify upstream signature, pin the SHA256
cigbuild sig     <pkg> <url|->...  check pinned sources against upstream signatures, record the URLs
cigbuild info    <pkg>      show a recipe
cigbuild pkgfile <pkg>      path of the package file for the current recipe
```

Packages are tarballs with a file list and checksum in `/var/cig/pkgs/`.
All package contents are owned by root. After `/bin`, `/sbin` and `/lib` are
merged into `/usr`, relative links that would point outside the package are
rewritten automatically.

### Recipe format

```sh
name=dwl
version=0.8
source="https://codeberg.org/dwl/dwl/releases/download/v$version/dwl-v$version.tar.gz"
signature=""                 # signature URL per source, or "-"
sha256="ccc8bbb3..."         # filled in by: cigbuild pin dwl
depends="wlroots libinput libxkbcommon wayland"
makedepends="wayland-protocols pkgconf"
style=make                   # gnu | meson | make | custom
```

Optional: `rel`, `configure_args`, `meson_args`, `make_args`, `wrksrc`,
`keep_static` (keep `*.a`, e.g. gcc's libgcc.a, musl's stubs), `nostrip`,
`noextract` (the recipe unpacks its sources itself, e.g. linux-firmware),
`config_files`, `link_dirs` (link a whole directory, e.g. kernel modules),
`copy_files` (install as a real copy, e.g. python), and the functions
`pre_build`, `do_build`, `do_install`, `post_install`. Sources may be written as
`filename::url`. Meson options that a package version doesn't define are
dropped and reported in the build log.

### Hardware-dependent builds

| Variable | Effect |
|---|---|
| `CIG_GPUS="amd intel"` | GPU vendors to build for (default: detected from `/sys`) |
| `CIG_PROFILE=generic` | build for all common hardware (prebuilt packages, install media) |
| `CIG_KERNEL_PROFILE=local\|generic` | kernel drivers: this machine (`lsmod`) or everything |
| `CIG_KERNEL_EXTRA_MODULES` | always include these kernel modules |
| `CIG_KERNEL_CMDLINE_EXTRA` | appended to the built-in command line |
| `CIG_ROOT` | root device (default `PARTLABEL=cig-root`) |
| `CIG_FIRMWARE=all` | install all firmware instead of the detected set |
| `/etc/cig/firmware.list` | explicit firmware list (the installer writes this) |
| `/etc/cig/efi-fallback` | also install the kernel as `EFI/BOOT/BOOTX64.EFI` |

The kernel base config is Alpine's `linux-lts` (pinned commit) with cig's
settings from `packages/linux/files/cig.config` on top; a reviewed cig base
config is planned.

## smoke

Installs, removes and audits packages.

```
/usr/pkg/<name>/<version>-<rel>-<id>/     the package's files
/usr/pkg/<name>/<...>/.meta/              file list, checksums, install hook, pristine /etc files
/usr/bin, /usr/lib, ...                   links into /usr/pkg
/etc                                      real files (editable)
/usr/pkg/INVENTORY                        what is installed and why (sealed with a checksum)
```

```
smoke add [-c|-p] [-y] <pkg>.. add and install: asks "compile on this device?" (-c yes,
                               -p use a prebuilt package) and "install?" (-y no questions)
smoke remove  <pkg>...         remove, then dependencies nothing needs anymore
smoke autoremove               remove orphaned dependencies
smoke update [-c|-p] [-y] [<pkg>...]
                               rebuild packages whose recipe changed (dependencies first),
                               report newer upstream releases; --check only reports
smoke list [-a [<word>]]       packages, reason, who needs them (-a: every available recipe
                               by category; a word searches name, description and category)
smoke why     <pkg>            why a package is installed
smoke files   <pkg>            files of a package
smoke mark    <reason> <pkg>   explicit | dependency | build
smoke audit [--quick]          check the system against the inventory
smoke hooks   <pkg>... | --all run a package's setup again
```

Install reasons: **explicit** (asked for), **dependency** (needed by another
package; removed automatically when nothing needs it), **build** (build tools;
never removed automatically).

Every build gets its own folder, so links switch atomically: even the running C
library or shell is replaced safely, and the old build is removed afterwards.
Config files changed by the user are kept; the new version is saved as `*.new`.

`smoke audit` reports: package folders not in the inventory, modified package
files, files in `/usr` that are not links into `/usr/pkg`, broken links, links
replaced by real files, changed configuration, orphaned dependencies, and a
hand-edited inventory (smoke then refuses to write until it is resolved).
`--quick` skips the package checksums. Paths in `/etc/smoke/audit.ignore` are
skipped.

Upstream releases: `cigbuild latest <pkg>...` finds each recipe's newest stable release
(git tags, download pages, PyPI); `scripts/check-updates.sh` prints the table for all
recipes. A recipe may limit it with `track=` (a version series, e.g. the kernel's LTS),
`stable=` (a pattern) or point it elsewhere with `upstream=` / `upstream_version()`.

## Installing

`cig-install` (run as root on the install medium's live system) shows one main menu
with every section and its current value, like archinstall: arrow keys move, Enter
edits a section, Esc goes back, Install is at the bottom.

| Section | |
|---|---|
| Disk | target disk (the running system's disk is not offered); **auto** (erase, default layout: ESP 512M, system, optional swap and `/home`) or **custom** (partition editor: keep, delete, add, format, mount points) |
| Identity | hostname, user (in `wheel`, `audio`, `video`, `input`), root locked or with password |
| Components | from the recipes' `group=` / `default=`; base packages always |
| Hardware | detected GPU and network, firmware per driver (toggle), optional WiFi network |
| Security | optional layers (placeholders for now) |
| Build | packages compiled here or prebuilt; kernel compiled for this machine (default) or the medium's generic kernel (with a warning) |

Nothing is written before the summary and typing the disk name; the summary
lists every partition that is deleted or formatted. The installer writes the
partition table in one step (GPT: ESP, `cig-root`, optional `cig-swap` and
`cig-home`; kept partitions keep their place and IDs, so an existing `/home` or
another system's ESP can stay), formats, writes fstab by UUID,
installs the packages with smoke, compiles the kernel for the detected hardware
(root found by PARTUUID, its own module signing key), runs the package setup,
creates the users, and enables networking. It ends with `smoke audit` against the new
system: it must contain exactly what was chosen. Sources and prebuilt packages come
from the medium only when a chosen package needs them. Log: `/var/log/cig-install.log`.

The installed system boots through the UEFI fallback path for now
(`EFI/BOOT/BOOTX64.EFI`); boot entries come later.

### The install medium

`scripts/build-media.sh` (in the dev chroot, as root) builds `cig-<version>.img`: a GPT
with an ESP (the kernel as `EFI/BOOT/BOOTX64.EFI`) and a root partition named `cig-media`.
It boots as a live system: the medium stays read-only, `/etc`, `/var`, `/home`, `/root`
and `/mnt` live in RAM, and `/var/cig` on the medium holds every source and prebuilt
package for the installer. Logins: `root` and `cig`, password `ciglinux` (nothing on the
live system listens on the network). Write it to a USB stick with `dd`.

### Testing in QEMU

```
qemu-img create -f raw ~/cig-target.img 40G
CIG_IMG=~/cig/cig-0.2.1.img CIG_TARGET=~/cig-target.img scripts/run-vm.sh
# in the VM, as root:  cig-install
CIG_IMG=~/cig-target.img scripts/run-vm.sh      # boot the installed disk alone
```

Boot an installed target disk alone, never together with the dev image: both
contain a partition named `cig-root`. Recreate the target image for each test.

## Building

Host: Void Linux (x86_64). The bootstrap creates a disk image with a musl
toolchain and a minimal system; from there `cigbuild` builds everything.

| # | Step | Where |
|---|---|---|
| 1 | `scripts/fetch-sources.sh` | host |
| 2 | `scripts/build-toolchain.sh`, `scripts/build-temp.sh` | host |
| 3 | `scripts/enter-chroot.sh [-c "<command>"]` | host (sudo), mounts the repo at `/cig`; `cigbuild` from the repo, the installed C `smoke` with the repo's recipes |
| 4 | `scripts/prepare-base.sh` → `build-base.sh` | host → chroot |
| 5 | `cigbuild pin ...` | host (gpg) |
| 6 | `smoke add -c <packages>` | chroot |
| 7 | `scripts/build-media.sh` | chroot: the install medium (after the media kernel and firmware, see the script) |
| 8 | `scripts/run-vm.sh` | host: boot an image in QEMU (UEFI) |

The bootstrap scripts will be replaced by building from the install medium.

cig is an independent distribution built from scratch. The bootstrap method
(cross toolchain → temporary tools → chroot → final system) was inspired by
Linux From Scratch and Musl-LFS; cig does not follow either book.

## Pinned versions and why

| Package | Pin | Reason |
|---|---|---|
| gawk | 5.3.x | gawk 5.4 makes GCC 16's option generator produce broken output |
| git | 2.x, `NO_RUST=1` | git 2.54+ builds Rust by default; git 3.0 makes Rust mandatory |
| Python | 3.13.x | last series with GPG-signed releases; build tool only |
| make, flex, gmp, mpfr, mpc | built as C17 | pre-C23 code; GCC 15+ defaults to C23 |
| ninja | samurai | same job in C, ~4k lines |
| musl | provides `ldd` | autoconf's `config.guess` detects musl via `ldd --version` |
| gcc, binutils | explicit `x86_64-pc-linux-musl` | never let the build guess the system type |

## Roadmap

See [`ROADMAP.md`](ROADMAP.md). In short:

- [x] Phase 0 – Foundation: toolchain, userland, init, desktop, cigbuild, kernel, firmware
- [x] Phase 1 – smoke: symlink farm, inventory with install reasons, autoremove, audit
- [x] Phase 2 – Installer (shell TUI), tested in QEMU (0.2.0)
- [ ] Phase 3 – Install media (ISO), first bare-metal install, day-one usability (ALSA, clipboard, screenshots, DNS);
  the medium, clipboard and screenshots are done
- [ ] 0.3.x – GPU acceleration: Mesa without LLVM (RADV + Zink); built, not yet tested on an AMD GPU
- [ ] Phase 4 – Optional components (PipeWire, Bluetooth, wmenu), UEFI boot entries, libre-meter
- [ ] Phase 5 – Security layers (allowlisting), read-only root, own kernel base config
- [ ] Phase 6 – Browser, hardened_malloc, sandboxing, smoke updates
- [ ] Phase 7 – Code quality: sanitizers, strict flags, fuzzing

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
