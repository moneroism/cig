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

## Versions

| Version | Meaning |
|---|---|
| **X.0.0** | stable release, production-ready on real hardware (1.0.0 = first stable) |
| **0.X.0** | beta / testing release: may run on hardware, but unstable |
| **x.y.Z** | hotfixes and small additions to that release (0.1.1, 1.0.1) |

The current version is in `VERSION` in the repository root; `cig-base` writes it
into `/usr/lib/os-release` of every installed system.

| Version | Reached when |
|---|---|
| 0.1.0 | Phase 0 + 1: boots in QEMU, fully managed by smoke |
| 0.2.0 | Phase 2: the installer installs a bootable system ← current |
| 0.3.0 | Phase 3: install media (ISO) and first bare-metal install |
| 0.4.0 | Phase 4: optional components |
| 0.5.0 | Phase 5: security layers |
| 1.0.0 | stable on real hardware |

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

### Phase 0 – Foundation ✅ done (0.1.0)

- musl toolchain, BusyBox userland, sinit + runit, EFISTUB boot
- networking, OpenSSL, curl, git, wpa_supplicant
- Wayland desktop: wlroots, dwl, foot (CPU rendering)
- `cigbuild` with recipes for every package, signature-checked pinning
- linux-hardened kernel recipe: per-machine config, signed modules, lockdown
- linux-firmware recipe: only the firmware the machine's drivers request
- bootstrap components as recipes (musl, gcc, binutils, busybox, sinit, …)

**Exit criteria (met):** the whole system rebuilds from recipes and boots in QEMU.

### Phase 1 – smoke ✅ done (0.1.0)

- packages installed into `/usr/pkg/<name>/<version>/`, linked into `/usr` (symlink farm)
- inventory as a plain text file: name, version, reason (`explicit` / `dependency`),
  needed-by, source checksum
- removing a package also removes dependencies nothing else needs
- `smoke audit`: reports software outside the inventory, files in `/usr` that are not
  links into `/usr/pkg`, broken links, changed checksums, orphans
- the inventory protected (root-owned, own checksum)
- recipes unchanged; cigbuild builds, smoke installs

**Exit criteria:** the running system is fully managed by smoke and `smoke audit` is clean.

### Phase 2 – Installer (shell TUI) ✅ done (0.2.0)

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

### Phase 3 – Install media (ISO) and first bare-metal install ⏭ next (0.3.0)

Decisions (after Phase 2):
- **Installer default: compile everything on the machine.** Kernel: compiled for this
  machine (default) or a **generic kernel** as an option, with a warning (all drivers,
  shared prebuilt module key).
- **Compiling happens on the target disk** (`/var/cig` of the new system), not in the
  live system's RAM; sources and packages stay on the installed system.
- **Build tools are off by default** on installed systems; the first compile asks for them.
- **smoke = Obtainium for Linux** (design: [`docs/smoke.md`](docs/smoke.md)): no central
  repository; `smoke add <name|url>` adds *and* installs (there is no `smoke install`),
  asks "compile on device?" (`-c` = yes) and "install package?"; a signed name file maps
  words to official links and key fingerprints; unsigned upstreams install with a warning.
- **cig updates** come from the cig repository (GitHub, later Codeberg), compiled and
  verified on the device; tags signed by the project key.
- **DNS** is an installer choice: unbound + DoT by default (provider list editable),
  a local recursive resolver (no third parties), or plain DHCP DNS.
- **Route to bare metal: an ISO written to a USB stick.**

Work:
- xorriso recipe; hybrid ISO bootable from USB and optical media via UEFI
- live mode in `rc.init`: read-only ISO root, `/etc` `/var` `/home` `/tmp` in RAM
- media kernel: broad drivers, ISO9660 built in, root by its own partition name
  (never confused with an installed `cig-root`)
- media contents: base system, build tools, cigbuild/smoke/installer, all sources
  (offline compiling), prebuilt generic kernel
- `scripts/build-iso.sh` → `cig-<version>.iso`
- installer: compile-by-default, generic-kernel option with warning, builds on the target
- smoke: `add` (replaces `install`) with the compile/install questions, `-c`, the
  build-tools prompt, the unsigned warning, and name-file lookup (local file first)
- unbound recipe; DNS choice in the installer
- day-one usability (so cig can be used for a full day on the PC):
  sound (ALSA), clipboard (wl-clipboard), screenshots (grim), and a web browser
  (decision pending: which one, and its cost in build time and code size)
- install on the development PC's SATA SSD; verify boot, WiFi, display, input, poweroff

**Exit criteria:** cig installed from the ISO on the PC and usable for a full day;
the bugs found that day are the input for 0.3.x.

### Phase 4 – Optional components (0.4.0)

- components as recipes, offered in the installer:
  PipeWire (optional), Bluetooth = BlueZ + D-Bus (optional),
  wmenu (default on, uncheckable); ALSA moves to Phase 3
- UEFI boot entries (efibootmgr) instead of only the fallback path

**Exit criteria:** every component installs and works on the PC.

### Phase 5 – Security layers (0.5.0)

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
- smoke: `update`, name-file recipes, generated recipe drafts, builds as an unprivileged
  user, recipe diffs on update, on-device signature checks (gpgv, later minisign/signify),
  optional glibc compatibility for prebuilt upstream binaries
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
