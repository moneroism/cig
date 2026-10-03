# cig – goals and roadmap

Reference document. It states what cig is meant to be and in which order
things get done. Phases are ordered, not dated: a phase starts when the
previous one has met its exit criteria. Anything that depends on real
hardware waits until cig has booted on real hardware.

## Goals

| Goal | Meaning |
|---|---|
| Minimal attack surface | Small implementations, unused features compiled out, nothing running that isn't needed |
| Every source verified | GPG signatures checked when a recipe is pinned; SHA256 pinned in every recipe; unsigned sources marked openly |
| Compiled on the machine | Kernel and packages built for the machine they run on; every install gets its own module signing key |
| Nothing hardcoded | Hardware choices are detected or chosen, every optional component can be deselected |
| Upstream defaults | No theming; users configure their own system |
| Auditable | One readable inventory says what is installed and why; the system can be checked against it |
| For others, not one machine | Installer, install media and documentation are part of the project |

## Names

| Name | What it is |
|---|---|
| cig | the distribution |
| cigbuild | build tool: recipe → verified source → package |
| smoke | package manager: install, remove, inventory, audit |

cig is an independent distribution built from scratch. The bootstrap method
(cross toolchain → temporary tools → chroot → final system) was inspired by
LFS and Musl-LFS; cig does not follow either book.

## Phases

### Phase 0 – Foundation ✅ done

- musl toolchain, BusyBox userland, sinit + runit, EFISTUB boot
- networking, OpenSSL, curl, git, wpa_supplicant
- Wayland desktop: wlroots, dwl, foot (CPU rendering)
- `cigbuild` with recipes for every package, signature-checked pinning
- linux-hardened kernel recipe: per-machine config, signed modules, lockdown
- linux-firmware recipe: only the firmware the machine's drivers request
- bootstrap components as recipes (musl, gcc, binutils, busybox, sinit, …)

**Exit criteria (met):** the whole system rebuilds from recipes and boots in QEMU.

### Phase 1 – smoke ⏭ next

- packages installed into `/usr/pkg/<name>/<version>/`, linked into `/usr` (symlink farm)
- inventory as a plain text file: name, version, reason (`explicit` / `dependency`),
  needed-by, source checksum
- removing a package also removes dependencies nothing else needs
- `smoke audit`: reports software outside the inventory, files in `/usr` that are not
  links into `/usr/pkg`, broken links, changed checksums, orphans
- the inventory protected (root-owned, own checksum)
- recipes unchanged; cigbuild builds, smoke installs

**Exit criteria:** the running system is fully managed by smoke and `smoke audit` is clean.

### Phase 2 – Installer (shell TUI)

Numbered menus and `[x]` checkboxes, no extra dependencies. Menus are built
from recipe data (group, default), not from a fixed list.

| Screen | Content |
|---|---|
| Disk | choose disk, confirmation before erasing; GPT: ESP, `cig-root`, `cig-home` |
| Identity | hostname, user, passwords; user in `wheel`, `audio`, `video`, `input` |
| Components | desktop, launcher, sound, Bluetooth … (from recipes) |
| Hardware | detected devices and the firmware they need; adjustable |
| Security | allowlist layers 1–3 (see Phase 5) – **placeholders, shown but not selectable yet** |
| Build mode | compile on this machine (default) or prebuilt packages |
| Summary | all choices, last chance to go back |

Install: partition, format, build and install the selected packages with
smoke, compile the kernel for the detected hardware, write fstab, create users.
First boot path: UEFI fallback (`EFI/BOOT/BOOTX64.EFI`).

Testing: in QEMU, the running VM installs onto a second, empty disk.

**Exit criteria:** an install onto an empty VM disk boots on its own.

### Phase 3 – First bare-metal boot

- install onto the SATA SSD of the development PC, run from the cig chroot on the
  host (no install media needed yet)
- verify on real hardware: boot, WiFi, display, input, poweroff
- fix whatever real hardware reveals

**Exit criteria:** cig boots on the PC and is usable for a session.

Only after this phase are hardware-specific decisions made.

### Phase 4 – Optional components and install media

- components as recipes, offered in the installer:
  ALSA (default on), PipeWire (optional), Bluetooth = BlueZ + D-Bus (optional),
  wmenu (default on, uncheckable)
- install media: bootable USB image with a broad kernel, cigbuild, smoke, all recipes,
  all sources, all firmware and the installer
- UEFI boot entries (efibootmgr) instead of only the fallback path

**Exit criteria:** cig installs from USB on a machine other than the development PC.

### Phase 5 – Security layers

Each layer is optional in the installer.

| Layer | What it does |
|---|---|
| 1 – Only packaged programs run | executables only under `/usr/pkg`; `/home`, `/tmp`, `/var`, `/run`, `/dev/shm` mounted `noexec`; `vm.memfd_noexec=2` |
| 2 – Only listed software starts | services and session autostart only from the inventory; `smoke audit` at boot |
| 3 – Kernel-enforced allowlist | IMA appraisal: the kernel runs only files whose hashes smoke has signed |

Known limits, stated openly: interpreters can run scripts from writable places;
the inventory must be protected (read-only root).

Also in this phase:
- read-only root filesystem
- reviewed cig kernel base config (replacing Alpine's), with loadpin and safesetid
- module loading locked after boot as an installer option

**Exit criteria:** each layer can be enabled at install time and is documented.

### Phase 6 – Later

- GPU acceleration (Mesa) – needs a decision on LLVM
- hardened_malloc
- sandboxing and privilege separation
- app catalog for smoke (git + text inventory, optional on-device compile)
- `sudo` compatibility command that calls doas
- user power helper (poweroff/reboot without doas)
- Python removed from finished systems (build tool only)

### Phase 7 – Code quality

After everything is running:

- run packages and cig's own tools under sanitizers (AddressSanitizer,
  UndefinedBehaviorSanitizer, LeakSanitizer) in a separate test build
- compile with strict warning flags (`-Wall -Wextra`, selected `-Werror`) and fix or
  document what they find
- additional hardening flags where they don't break software
  (`-fstack-clash-protection`, `-fcf-protection`, `-ftrivial-auto-var-init=zero`)
- static analysis of cig's own code (shellcheck for the scripts)
- memory leak and fuzz testing of the parts exposed to input (network, file parsers)

**Exit criteria:** every package has a recorded sanitizer/strict-flags result.

## Housekeeping (whenever convenient)

- rename bootstrap leftovers: `/mnt/lfs` → `/mnt/cig`, `lfs.img` → `cig.img`,
  `x86_64-lfs-linux-musl` → `x86_64-cig-linux-musl`
- rewrite the bootstrap scripts as part of the install media build
- pkgconf: replace the 2.9.99 pre-release with the newest stable release
- `cig-kernel-install`: don't overwrite the fallback kernel with an identical one
- package `cigbuild` and `smoke` themselves as recipes (instead of links to the repo)
- git 3.0 will require Rust: decide between adding Rust and staying on git 2.x
