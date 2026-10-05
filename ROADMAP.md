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
| Minimal installed system | Everything beyond the base is the user's choice, at install time or later. The installer and install media may be large; the installed system may not |
| Small footprint | An installed system with dwl uses **100 MB of RAM or less** after boot |

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
| 0.2.0 | Phase 2: the installer installs a bootable system |
| 0.2.1 | partition editor and swap, signature URLs, fixes ← current |
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
| Disk | choose disk; auto layout or partition editor; confirmation before writing; GPT: ESP, `cig-root`, optional `cig-swap`, `cig-home` |
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

- **The installer is feature-heavy, the installed system is not** (2026-10-05): the
  installer and the media may carry anything they need; an installed system contains only
  what the user chose. Nothing is copied to the target only to be deleted later; instead
  the install ends with `smoke audit` against the target, and anything not in the
  inventory fails the install loudly.
- **Languages** (2026-10-05): **smoke is rewritten in C** (security-critical, runs as root,
  parses packages and the inventory; C adds no dependency, gcc and musl are already the
  base). **The installer is rewritten in C with ncurses**, archinstall-style: a main menu
  with every section and its current value, arrow keys, Enter to edit, Install at the
  bottom. ncurses goes on the media only. **cigbuild stays shell**: recipes are shell and
  run configure/make anyway. Rust and Go are out (toolchain size); Hare was considered
  (young, few libraries). Phase 7's strict flags, sanitizers and fuzzing apply to both.

Work, first block (before the ISO):
- ~~split `cig-tools`: smoke + cigbuild + recipes on installed systems, the installer only
  on the media~~ (done: `cig-installer`)
- ~~installer copies to the target only the sources of the chosen packages (and only when
  compiling) and no prebuilt packages that were not chosen; final `smoke audit` check~~
  (done: `CIG_SOURCE_MIRROR` / `CIG_PKG_MIRROR`, copied only when needed)
- ~~smoke in C: same commands, inventory format and package format as the shell version,
  so both can be tested against each other on the same system~~ (done: `src/smoke`,
  `test/compare.sh`); remaining: test on a real install, then retire the shell version
- installer in C + ncurses with the same screens and features as the shell version
  (partition editor included), then the shell installer is removed: written
  (`src/installer`), auto layout installed and booted in the VM (2026-10-05); remaining:
  VM test of the partition editor keeping /home, then remove `cig-install-sh` and the shell smoke

Work:
- xorriso recipe; hybrid ISO bootable from USB and optical media via UEFI
- live mode in `rc.init`: read-only ISO root, `/etc` `/var` `/home` `/tmp` in RAM
- `cig-live` (media only, no `group=`): logins `root` / `cig-linux` (for the installer) and
  `cig-linux` / `cig-linux` (doas), created at boot; a login banner (`/etc/issue`) with the
  logo and the install hints, from `packages/cig-live/files/logo.txt` and `text.txt`
  (plain ASCII, <= 80 columns, `{VERSION}` filled in at build time). Nothing on the live
  system listens on the network, so the known passwords only matter at the keyboard
- media kernel: broad drivers, ISO9660 built in, root by its own partition name
  (never confused with an installed `cig-root`)
- media contents: base system, build tools, cigbuild/smoke/installer, all sources
  (offline compiling), prebuilt generic kernel
- `scripts/build-iso.sh` → `cig-<version>.iso`
- ~~installer: compile-by-default, generic-kernel option with warning, builds on the target~~ (done)
- ~~installer: auto partitioning with optional swap, partition editor~~ (done)
- ~~smoke: `add` (replaces `install`) with the compile/install questions, `-c`, the
  build-tools prompt, the unsigned warning~~ (done); name-file lookup (local file first)
- unbound recipe; DNS choice in the installer
- day-one usability (so cig can be used for a full day on the PC), all optional:
  sound (ALSA), clipboard (wl-clipboard), screenshots (grim). No browser yet (see Phase 6)
- install on the development PC's SATA SSD; verify boot, WiFi, display, input, poweroff

**Exit criteria:** cig installed from the ISO on the PC and usable for a full day;
an installed system with dwl uses ≤ 100 MB RAM after boot (measured with `free -m`);
the bugs found that day are the input for 0.3.x.

### 0.3.x – GPU acceleration (after the first bare-metal install)

Mesa **without LLVM**: RADV (Vulkan, ACO shader compiler) for AMD, Zink for OpenGL on
top of Vulkan; wlroots renders through Vulkan. GPU drivers follow the detected hardware
(`lib/hardware.sh`). New recipes: Vulkan headers and loader, glslang, CMake, Python
mako/PyYAML (build-only). Tested on the PC's RX570 (the VM has no AMD GPU).
Optional in the installer; the RAM target must still hold.



### Phase 4 – Optional components (0.4.0)

- components as recipes, offered in the installer:
  PipeWire (optional), Bluetooth = BlueZ + D-Bus (optional),
  wmenu (default on, uncheckable); ALSA moves to Phase 3
- UEFI boot entries (efibootmgr) instead of only the fallback path
- **libre-meter** in the installer, right before the final summary: how libre the
  installed system will be, and which software changes would make it more libre
  - assesses every part cig installs: packages (recipe `license=`), kernel and
    kernel config, and each firmware file (license from linux-firmware's `WHENCE`);
    states openly what lies outside cig (UEFI firmware, Intel ME / AMD PSP, device
    firmware already on the hardware, microcode inside the UEFI firmware)
  - suggests software changes first: a free alternative for a non-free package,
    free firmware where it exists for the device (e.g. open `ath9k_htc` firmware,
    a free driver instead of one that needs a blob), dropping firmware no device
    uses, a kernel config without blob-loading for a subsystem that doesn't need it;
    each with its cost (lost function, performance). Hardware changes come last,
    as information only
  - two scores: **libre overall** (share of free parts in what will be installed) and
    **libre vs. possible** (overall score compared with the best score this hardware
    can reach with free software), so a machine that cannot run without blobs is not
    judged against an ideal it cannot meet
  - nothing changes without the user choosing it; suggestions link to the screen
    (components, hardware) where they can be applied
  - needs `license=` in every recipe and a list of free alternatives per non-free item

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

- web browser as an optional component (Firefox-class; needs Rust, LLVM/clang, Node.js
  to build, glibc compatibility would allow upstream binaries instead)
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

- rewrite the bootstrap scripts as part of the install media build
- git: stay on 2.x (`NO_RUST=1`) while it is maintained; Rust only once 2.x is no longer maintained
