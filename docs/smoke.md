# smoke – design

smoke is cig's package manager: Obtainium for Linux, with hardening.
Software comes from its upstream source (GitHub, Codeberg, project sites),
not from a central repository. smoke verifies what it can, builds on the
device by default, records everything in one readable inventory, and checks
the system against it.

Status markers: **(done)** works today, **(planned)** designed, not built yet.

## Principles

- **No central repository.** Every package comes from its upstream.
- **Verify on the device, trust as little as possible.** Signatures and
  checksums are checked on the machine that installs; the cig developer is
  not a trusted party for anything that can be verified.
- **Security-oriented, not opinionated.** Secure defaults; the user can
  change every one of them.
- **Auditable.** One inventory says what is installed and why.

## Commands

```
smoke add <name|url>...       add and install                          (done for cig's recipes;
                                                                       names/links planned)
smoke add -c <name|url>...    compile on this device without asking    (done)
smoke add -p <name|url>...    use a prebuilt package without asking    (done)
smoke add -y ...              no questions (scripts, the installer)    (done)
smoke remove <pkg>...         remove, then dependencies nothing needs   (done)
smoke update [<pkg>...]       check upstream for new releases, update   (planned)
smoke list                    packages, reason, who needs them          (done)
smoke why <pkg>               why a package is installed                (done)
smoke files <pkg>             files of a package                        (done)
smoke mark <reason> <pkg>     explicit | dependency | build             (done)
smoke autoremove              remove orphaned dependencies              (done)
smoke audit [--quick]         check the system against the inventory    (done)
smoke hooks <pkg>... | --all  run a package's setup again               (done)
```

There is no `smoke install`: adding an app *is* installing it.

### `smoke add foo`

1. **Resolve** `foo`: a full link is used as-is; a name is looked up in the
   name file (below).
2. **Compile on device?** `[Y/n]` – skipped (yes) with `-c`.
   - yes: if build tools are missing, smoke asks whether to install them first.
   - no: use a prebuilt release from upstream (must run on musl; glibc
     compatibility is planned as an option).
3. **Show** source link, version, signature status, and the recipe if it was
   generated or changed.
   - not signed → `warning: <foo> is not signed by its upstream`
   - key differs from the one seen before → loud warning, default answer *no*
4. **Install package?** `[y/N]`
5. Build (if compiling), install, record in the inventory, run the package's setup.

## The name file

Maps plain words to official links – "DNS for packages".

```
# name        link                                                      key fingerprint
example       https://codeberg.org/someone/example                      <40-hex-digit fingerprint of the upstream signing key>
foot          https://codeberg.org/dnkl/foot                            -
dwl           https://codeberg.org/dwl/dwl                              -
```

- `-` = upstream doesn't sign; smoke warns on install.
- An entry may point to a reviewed recipe (see "Recipes").
- **Official file:** `/usr/share/cig/names`, signed by the cig project key
  (`names.sig`). smoke refuses an official file whose signature doesn't match.
- **Local file:** `/etc/smoke/names`, the user's own entries and overrides;
  checked first, not signed (the user trusts themselves).

The project key is the one point of trust in the cig developer. It only maps
names to links; every link and key is shown before installing and can be
overridden locally.

## Trust model

| Check | How |
|---|---|
| Source integrity | SHA256 pinned in the recipe; mismatch = abort, file deleted (done) |
| Upstream signature | verified on the device with `gpgv` (planned; later also minisign/signify) |
| Which key is valid | the fingerprint from the name file; the key itself may come from anywhere (keyserver, project site) – only a key with that fingerprint is accepted |
| Apps added by link | key remembered on first install (trust on first use); a later change is a loud warning |
| Unsigned upstream | allowed, with a warning on every install |
| Name file | signed by the cig project key |
| cig itself | git tags signed by the cig project key |

## Recipes

How to build a package (format: see `README.md`, "Recipe format").
Where a recipe comes from, in order:

1. **Local recipe** – written or edited by the user; always wins. (planned)
2. **Name-file recipe** – a reviewed recipe for common apps. (planned)
3. **Generated draft** – smoke detects the build system and writes a recipe,
   shows it, and builds after confirmation. (planned)
   - `meson.build` → meson, `CMakeLists.txt` → CMake, `configure` → autotools,
     `Cargo.toml` → Rust, `go.mod` → Go, `Makefile` → make
   - dependencies from meson/CMake declarations (pkg-config names → cig packages);
     anything unresolved stops with a clear message instead of guessing

cig's own system packages are recipes in the cig repository.

## Builds

- **As an unprivileged build user by default** (planned); building as root is
  a user choice. Only installing needs root.
- Build tools (gcc, make, meson, Python, …) are **not installed by default**;
  the first compile asks for them.
- On upgrade, a recipe that changed is **shown as a diff** before building (planned).

## Updates

- **Apps:** `smoke update` checks each app's upstream (release tags) and
  updates through the same flow as `add`. (planned)
- **cig itself:** recipes and tools come from the cig repository
  (GitHub; Codeberg later), are compiled on the device and verified there.
  The repository's tags are signed by the project key.

## Over the network (decided 2026-10-05, planned)

- **Recipes** live in their own repository (`cig-recipes` on GitHub), separate from the
  tools. `smoke sync` fetches it: a release archive with curl, verified with its detached
  signature before anything is used (no git needed on the device). Releases are signed by
  the cig project key.
- **Signature checks on the device: `gpgv`** (GnuPG's verify-only tool), because upstreams
  sign with OpenPGP. It is a package that the installer's package screen has ticked by
  default; unticking it shows a warning (yes / no) explaining that downloads can then only
  be checked against their pinned SHA256, not against their authors' keys.
- **Prebuilt packages** are optional and signed by the project key. **Reproducible builds**
  make them checkable: anyone can rebuild a recipe and compare the checksum, so trusting
  the prebuilt package never means trusting the cig developer. Compiling on the device
  stays the default.
- **No mirrors.** Sources come from their upstreams; cig's own downloads (recipes, prebuilt
  packages) from the repository's release pages. HTTPS only, and nothing is used before
  its signature or pinned checksum has been verified.

## Layout

```
/usr/pkg/<name>/<version>-<rel>-<id>/     a package's files
/usr/pkg/<name>/<...>/.meta/              file list, checksums, setup hook, pristine /etc files
/usr/bin, /usr/lib, ...                   links into /usr/pkg
/etc                                      real files (editable; kept on updates, new version as *.new)
/usr/pkg/INVENTORY                        what is installed and why (sealed with a checksum)
```

Install reasons: **explicit** (asked for), **dependency** (removed automatically
when nothing needs it), **build** (build tools; never removed automatically).

## Audit

`smoke audit` reports package folders outside the inventory, modified package
files, files in `/usr` that aren't links into `/usr/pkg`, broken links, links
replaced by real files, changed configuration, orphans, and a hand-edited
inventory. It also reads every installed ELF file's needed libraries (`DT_NEEDED`) and
reports any that no installed package provides, so a missing runtime library shows up
before a program fails with "Error relocating" (links are resolved inside `SMOKE_ROOT`).
(done)

The optional allowlisting layers (see `ROADMAP.md`, Phase 5) build on the
inventory: only software it lists may run or start. On-device compiling needs
an exception for the build directory while a build runs.
