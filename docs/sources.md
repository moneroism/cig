# Sources and their authenticity

## Policy

cig never treats a hosting domain (SourceForge, GitHub, Codeberg, PyPI, any mirror) as an
authority by itself. A source is **verified** only when its authenticity comes from its
upstream project's own cryptographic statement:

| Method | Recipe entry (`signature=`) | What is checked |
|---|---|---|
| upstream GPG signature | `<url>` | a detached signature of the file itself |
| signed checksum file | `sums=<url>` | a GPG-signed list of checksums (inline, or with `<url>.asc`) that names the file |
| signed git tag | `tag=<git url>#<tag>` | the tag's GPG signature (`git verify-tag`), and the archive holds exactly the tag's tree, file for file |

Where sources may come from at all is listed in `lib/hosts` (decided 2026-10-07): the forges
(GitHub, GitLab, Codeberg, sourcehut) and each project's own official release site, named
there. cigbuild refuses any other host, plain HTTP, SourceForge, generic download sites and
third-party mirrors.

In every method the signer must be one of the recipe's `keys=` (primary key fingerprints).
A keyserver returns whatever key carries the signature's key ID, so a valid signature alone
does not say who signed: `pin` records the keys on first use and refuses any other key
afterwards. A new key is added only with `cigbuild trust <pkg> <fingerprint>`, after the
project announced it on its own site.

Where the check happens: every source has a pinned SHA256, and every device that builds a
source with a detached signature also checks that signature with `gpgv` against the recipe's
keys, whose public halves are in `keys/<fingerprint>.gpg`. Both must match (2026-11-17): the
signature says who made the file, the pin says which file. From 2026-10-07 until then signed
sources carried no pin (`sha256="-"`), and a download host could have served any older release
the same key had signed under the new version's name. All recipes were pinned again on
2026-11-17 (each file's signature checked once more, the hash compared with the cached file
and with the pin the recipe had before 2026-10-07 where the version is the same); a signed
source without a pin is now refused, `cigbuild pin` fills it in. Signed checksum files
are checked the same way since 2026-11-03: gpgv verifies the file (inline-signed, or with its
`<url>.asc`) and the source must match the SHA-256 or SHA-512 it lists. Signed tags need git
on the device, so they keep a pinned SHA256 (checked against the tag on the host), as unsigned
sources do (for them it is the only check). Offline, a checksum file that is not in the source
mirror leaves the pinned SHA256 to decide; a source without one is refused. A source with neither is trusted on first use on each device (`$CIG_VAR/tofu`).

Keys are fetched by ID from public keyservers only, never from the forge that hosts the code.
All checks also run on the host when a source is pinned (`cigbuild pin`, `cigbuild sig`). Every other source is **flagged**: its SHA256 was pinned
on first download (trust on first use), and `smoke add` warns about it on every install.

`scripts/audit-sources.sh` prints the current table (below, as of 2026-11-25).

## Flagged sources and why

| Package | Why authenticity is not established | Way out |
|---|---|---|
| libpng | release files (SourceForge) unsigned; the git tags are signed, but the current key (1FED507E…B292C64843FF5BCF) is published only on GitHub and not certified by the maintainer's keyserver key (F57A5503…C9E384533403C2F8) | maintainer publishes the key on a keyserver or cross-certifies it |
| libxml2 | GNOME does not sign tarballs; its sha256sum file is on the same host (the pin matches it) | signed git tags with an independently published key |
| glib | GNOME's release tarball is not the signed tag's tree (it bundles subprojects); GNOME does not sign tarballs | build from the signed tag with its subprojects pinned |
| pango, fontconfig, tllist, wmenu, seatd, pkgconf, perl | tags are signed, but the keys are not on public keyservers (or the signatures are SSH, which is not checked yet) | find the keys on an independent source; SSH tag signatures |
| json-c, libxkbcommon, tmux, libffi, samurai, vulkan-headers, labwc, pipewire (+ wireplumber), pipewire-bluetooth | tags unsigned (labwc: matches Alpine's SHA-512; pipewire, wireplumber: each tarball is its tag's tree, whose git archive matches Arch's BLAKE2 sum) (vulkan-headers: annotated but not verifiable), releases unsigned | none upstream |
| libyaml | release unsigned (GitHub); the tarball matches Alpine's SHA-512 (main/yaml) | none upstream |
| fftw, cava, iniparser | releases and tags unsigned (fftw.org: only an MD5 file on the same host); fftw and cava match Void's SHA256 and Alpine's SHA-512; iniparser's GitLab archive holds the same tree as the GitHub mirror's, whose SHA256 is in Arch's PKGBUILD | none upstream |
| glslang, fastfetch, wl-clipboard, jq, htop, dwl, vulkan-loader, brightnessctl | lightweight tags (cannot be signed), releases unsigned (jq: Sigstore attestation, htop: a SHA256 file on the same host) | Sigstore verification for jq |
| go | Go's source releases are not GPG-signed (the pins match go.dev's checksum list, same host); built from source alone, from Go 1.4 (C) up | signed releases |
| gn | no releases or signed tags; gn.googlesource.com generates archives per download (never byte-identical): the pin matches cig's cached copy, a fresh download fails | a git source type pinned by commit |
| nss (+ nspr) | Mozilla publishes only a SHA256SUMS file on the same host (the pin matches it) | signed releases |
| at-spi2-core | GNOME does not sign tarballs (its .sha256sum on the same host matches the pin) | signed git tags with a published key |
| esbuild | tag archives on GitHub, unsigned; golang.org/x/sys at the commit esbuild's go.mod names | none upstream |
| rust-bindgen, chromium (crates) | crates.io has no signatures; every .crate pin matches the checksum in the Cargo.lock that names it (bindgen 71, crubit + gnrt 336) | crates.io signing (not available) |
| chromium | Google's official tarball is unsigned (a hashes file on the same host matches the pin); crubit is a GitHub commit archive; the musl patches are Alpine's (aports commit 7628bce8) and copium's (157.1), refreshed for patch without fuzz | signed releases |
| rust (patches) | Alpine's musl patches from aports at a pinned commit (the compiler and the seed themselves are signed) | signed aports commits |
| python-mako, -markupsafe, -packaging, -pyyaml | PyPI: no GPG signatures | Sigstore (PEP 740) attestations |
| linux (Alpine config), elfutils (musl patch) | files from Alpine's aports at a pinned commit; the commit's authenticity is not checked | signed aports commits, or cig's own reviewed config (Phase 5) |
| ca-certificates | curl.se's extract of Mozilla's CA store, unsigned | build from Mozilla's certdata at a verified revision |
| freetype | signed (2.14.3), but the key E3067470…BE6C3AAC63AD8E3F ("Werner Lemberg <wl@gnu.org>", 2019) carries only its own signatures: his older key 58E0C111…C1A60EACE707FDA5, the one keys.openpgp.org verified for that address, does not certify it, and freetype.org names no key; trusted by the developer on 2026-11-03 (long-time maintainer, same address) | the maintainer cross-certifies the key or freetype.org publishes it |
| rsync | signed (3.5.1), but by C0E10545…6A64E8AA2EFBCF5D ("Zen Dodd", created 2026-04), a key rsync.samba.org does not name (it names Wayne Davison and Andrew Tridgell); not trusted, the SHA256 pin stays (2026-11-03) | rsync announces the new signer on its own site |
| lua, mandoc, sinit, tree, mtdev, font-jetbrains-mono, libudev-zero, musl-fts, musl-obstack, argp-standalone | no signature and no independently published checksum | none upstream |

## Current table

| Package | Source host | Authenticity |
|---|---|---|
| alsa-lib | www.alsa-project.org | upstream GPG signature |
| alsa-utils | www.alsa-project.org | upstream GPG signature |
| argp-standalone | github.com | **UNVERIFIED** (pinned SHA256 only, trusted on first use) |
| at-spi2-core | download.gnome.org | **UNVERIFIED** (pinned SHA256 only, trusted on first use) |
| autoconf | ftp.gnu.org | upstream GPG signature |
| automake | ftp.gnu.org | upstream GPG signature |
| bash | ftp.gnu.org | upstream GPG signature |
| basu | git.sr.ht | upstream GPG signature |
| binutils | ftp.gnu.org | upstream GPG signature |
| bison | ftp.gnu.org | upstream GPG signature |
| bluez | cdn.kernel.org | upstream GPG signature |
| brightnessctl | github.com | **UNVERIFIED** (pinned SHA256 only, trusted on first use) |
| busybox | busybox.net | upstream GPG signature |
| ca-certificates | curl.se | **UNVERIFIED** (pinned SHA256 only, trusted on first use) |
| cairo | cairographics.org | signed git tag (archive = tag tree) |
| cava | github.com | **UNVERIFIED** (pinned SHA256 only, trusted on first use) |
| chromium | commondatastorage.googleapis.com | **UNVERIFIED** (pinned SHA256 only, trusted on first use) |
| chromium | github.com | **UNVERIFIED** (pinned SHA256 only, trusted on first use) |
| chromium | static.crates.io | **UNVERIFIED** (pinned SHA256 only, trusted on first use) |
| chrony | chrony-project.org | upstream GPG signature |
| cmake | github.com | signed checksum file |
| compiler-rt | github.com | upstream GPG signature |
| curl | curl.se | upstream GPG signature |
| dbus | dbus.freedesktop.org | upstream GPG signature |
| dosfstools | github.com | upstream GPG signature |
| dwl | codeberg.org | **UNVERIFIED** (pinned SHA256 only, trusted on first use) |
| e2fsprogs | cdn.kernel.org | upstream GPG signature |
| elfutils | sourceware.org | upstream GPG signature |
| elfutils | gitlab.alpinelinux.org | **UNVERIFIED** (pinned SHA256 only, trusted on first use) |
| esbuild | github.com | **UNVERIFIED** (pinned SHA256 only, trusted on first use) |
| expat | github.com | upstream GPG signature |
| fastfetch | github.com | **UNVERIFIED** (pinned SHA256 only, trusted on first use) |
| fcft | codeberg.org | signed git tag (archive = tag tree) |
| fftw | www.fftw.org | **UNVERIFIED** (pinned SHA256 only, trusted on first use) |
| file | astron.com | upstream GPG signature |
| flex | github.com | upstream GPG signature |
| font-jetbrains-mono | github.com | **UNVERIFIED** (pinned SHA256 only, trusted on first use) |
| fontconfig | gitlab.freedesktop.org | **UNVERIFIED** (pinned SHA256 only, trusted on first use) |
| foot | codeberg.org | signed git tag (archive = tag tree) |
| freetype | download.savannah.gnu.org | upstream GPG signature |
| fribidi | github.com | signed git tag (archive = tag tree) |
| gawk | ftp.gnu.org | upstream GPG signature |
| gcc | ftp.gnu.org | upstream GPG signature |
| git | cdn.kernel.org | upstream GPG signature |
| glib | download.gnome.org | **UNVERIFIED** (pinned SHA256 only, trusted on first use) |
| glslang | github.com | **UNVERIFIED** (pinned SHA256 only, trusted on first use) |
| gmp | ftp.gnu.org | upstream GPG signature |
| gn | gn.googlesource.com | **UNVERIFIED** (pinned SHA256 only, trusted on first use) |
| gnutls | www.gnupg.org | upstream GPG signature |
| go | dl.google.com | **UNVERIFIED** (pinned SHA256 only, trusted on first use) |
| gperf | ftp.gnu.org | upstream GPG signature |
| gpgv | gnupg.org | upstream GPG signature |
| grim | gitlab.freedesktop.org | upstream GPG signature |
| harfbuzz | github.com | signed git tag (archive = tag tree) |
| htop | github.com | **UNVERIFIED** (pinned SHA256 only, trusted on first use) |
| hwdata | github.com | signed git tag (archive = tag tree) |
| iniparser | gitlab.com | **UNVERIFIED** (pinned SHA256 only, trusted on first use) |
| iwd | cdn.kernel.org | upstream GPG signature |
| jq | github.com | **UNVERIFIED** (pinned SHA256 only, trusted on first use) |
| json-c | github.com | **UNVERIFIED** (pinned SHA256 only, trusted on first use) |
| labwc | github.com | **UNVERIFIED** (pinned SHA256 only, trusted on first use) |
| less | www.greenwoodsoftware.com | upstream GPG signature |
| libassuan | gnupg.org | upstream GPG signature |
| libburn | files.libburnia-project.org | upstream GPG signature |
| libcap | cdn.kernel.org | upstream GPG signature |
| libdisplay-info | gitlab.freedesktop.org | signed git tag (archive = tag tree) |
| libdrm | dri.freedesktop.org | upstream GPG signature |
| libevdev | www.freedesktop.org | upstream GPG signature |
| libevent | github.com | upstream GPG signature |
| libffi | github.com | **UNVERIFIED** (pinned SHA256 only, trusted on first use) |
| libgcrypt | gnupg.org | upstream GPG signature |
| libgpg-error | gnupg.org | upstream GPG signature |
| libinput | gitlab.freedesktop.org | signed git tag (archive = tag tree) |
| libisofs | files.libburnia-project.org | upstream GPG signature |
| libjpeg-turbo | github.com | upstream GPG signature |
| libksba | gnupg.org | upstream GPG signature |
| libnl | github.com | upstream GPG signature |
| libpng | github.com | **UNVERIFIED** (pinned SHA256 only, trusted on first use) |
| libtool | ftp.gnu.org | upstream GPG signature |
| libudev-zero | github.com | **UNVERIFIED** (pinned SHA256 only, trusted on first use) |
| libxkbcommon | github.com | **UNVERIFIED** (pinned SHA256 only, trusted on first use) |
| libxml2 | download.gnome.org | **UNVERIFIED** (pinned SHA256 only, trusted on first use) |
| libyaml | github.com | **UNVERIFIED** (pinned SHA256 only, trusted on first use) |
| linux-firmware | cdn.kernel.org | upstream GPG signature |
| linux-headers | cdn.kernel.org | upstream GPG signature |
| linux | cdn.kernel.org | upstream GPG signature |
| linux | github.com | upstream GPG signature |
| linux | gitlab.alpinelinux.org | **UNVERIFIED** (pinned SHA256 only, trusted on first use) |
| llvm | github.com | upstream GPG signature |
| lua | www.lua.org | **UNVERIFIED** (pinned SHA256 only, trusted on first use) |
| m4 | ftp.gnu.org | upstream GPG signature |
| make | ftp.gnu.org | upstream GPG signature |
| mako | github.com | upstream GPG signature |
| mandoc | mandoc.bsd.lv | **UNVERIFIED** (pinned SHA256 only, trusted on first use) |
| mesa | archive.mesa3d.org | upstream GPG signature |
| meson | github.com | upstream GPG signature |
| mpc | ftp.gnu.org | upstream GPG signature |
| mpfr | www.mpfr.org | upstream GPG signature |
| mtdev | bitmath.org | **UNVERIFIED** (pinned SHA256 only, trusted on first use) |
| musl-fts | github.com | **UNVERIFIED** (pinned SHA256 only, trusted on first use) |
| musl-obstack | github.com | **UNVERIFIED** (pinned SHA256 only, trusted on first use) |
| musl | musl.libc.org | upstream GPG signature |
| nano | www.nano-editor.org | upstream GPG signature |
| ncurses | ftp.gnu.org | upstream GPG signature |
| nettle | ftp.gnu.org | upstream GPG signature |
| nnn | github.com | upstream GPG signature |
| nodejs | nodejs.org | signed checksum file |
| npth | gnupg.org | upstream GPG signature |
| nss | archive.mozilla.org | **UNVERIFIED** (pinned SHA256 only, trusted on first use) |
| opendoas | github.com | upstream GPG signature |
| openssh | cdn.openbsd.org | upstream GPG signature |
| openssl | github.com | upstream GPG signature |
| pango | download.gnome.org | **UNVERIFIED** (pinned SHA256 only, trusted on first use) |
| pcre2 | github.com | upstream GPG signature |
| perl | www.cpan.org | **UNVERIFIED** (pinned SHA256 only, trusted on first use) |
| pipewire-bluetooth | gitlab.freedesktop.org | **UNVERIFIED** (pinned SHA256 only, trusted on first use) |
| pipewire | gitlab.freedesktop.org | **UNVERIFIED** (pinned SHA256 only, trusted on first use) |
| pixman | www.x.org | signed checksum file |
| pkgconf | distfiles.ariadne.space | **UNVERIFIED** (pinned SHA256 only, trusted on first use) |
| python-mako | files.pythonhosted.org | **UNVERIFIED** (pinned SHA256 only, trusted on first use) |
| python-markupsafe | files.pythonhosted.org | **UNVERIFIED** (pinned SHA256 only, trusted on first use) |
| python-packaging | files.pythonhosted.org | **UNVERIFIED** (pinned SHA256 only, trusted on first use) |
| python-pyyaml | files.pythonhosted.org | **UNVERIFIED** (pinned SHA256 only, trusted on first use) |
| python | www.python.org | upstream GPG signature |
| readline | ftp.gnu.org | upstream GPG signature |
| rsync | download.samba.org | upstream GPG signature |
| rust-bindgen | github.com | **UNVERIFIED** (pinned SHA256 only, trusted on first use) |
| rust-bindgen | static.crates.io | **UNVERIFIED** (pinned SHA256 only, trusted on first use) |
| rust | static.rust-lang.org | upstream GPG signature |
| rust | gitlab.alpinelinux.org | **UNVERIFIED** (pinned SHA256 only, trusted on first use) |
| samurai | github.com | **UNVERIFIED** (pinned SHA256 only, trusted on first use) |
| sbc | cdn.kernel.org | upstream GPG signature |
| seatd | git.sr.ht | **UNVERIFIED** (pinned SHA256 only, trusted on first use) |
| sinit | dl.suckless.org | **UNVERIFIED** (pinned SHA256 only, trusted on first use) |
| slurp | github.com | upstream GPG signature |
| strace | github.com | upstream GPG signature |
| sway | github.com | upstream GPG signature |
| swaybg | github.com | upstream GPG signature |
| swayidle | github.com | upstream GPG signature |
| swaylock | github.com | upstream GPG signature |
| tllist | codeberg.org | **UNVERIFIED** (pinned SHA256 only, trusted on first use) |
| tmux | github.com | **UNVERIFIED** (pinned SHA256 only, trusted on first use) |
| tree | oldmanprogrammer.net | **UNVERIFIED** (pinned SHA256 only, trusted on first use) |
| typescript-go | github.com | **UNVERIFIED** (pinned SHA256 only, trusted on first use) |
| typescript-go | proxy.golang.org | **UNVERIFIED** (pinned SHA256 only, trusted on first use) |
| unbound | nlnetlabs.nl | upstream GPG signature |
| util-linux | cdn.kernel.org | upstream GPG signature |
| vim | github.com | signed git tag (archive = tag tree) |
| vulkan-headers | github.com | **UNVERIFIED** (pinned SHA256 only, trusted on first use) |
| vulkan-loader | github.com | **UNVERIFIED** (pinned SHA256 only, trusted on first use) |
| wayland-protocols | gitlab.freedesktop.org | upstream GPG signature |
| wayland | gitlab.freedesktop.org | upstream GPG signature |
| wireless-regdb | cdn.kernel.org | upstream GPG signature |
| wl-clipboard | github.com | **UNVERIFIED** (pinned SHA256 only, trusted on first use) |
| wlroots | gitlab.freedesktop.org | upstream GPG signature |
| wmenu | codeberg.org | **UNVERIFIED** (pinned SHA256 only, trusted on first use) |
| wpa_supplicant | w1.fi | upstream GPG signature |
| xkeyboard-config | www.x.org | upstream GPG signature |
| xorriso | files.libburnia-project.org | upstream GPG signature |
| xz | github.com | upstream GPG signature |
| yambar | codeberg.org | upstream GPG signature |
| zlib | github.com | upstream GPG signature |
| zstd | github.com | upstream GPG signature |

103 sources verified, 514 flagged.
