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

Keys are fetched by ID from public keyservers only, never from the forge that hosts the code.
All checks run once, on the host, when a source is pinned (`cigbuild pin`, `cigbuild sig`);
devices then check the pinned SHA256. Every other source is **flagged**: its SHA256 was pinned
on first download (trust on first use), and `smoke add` warns about it on every install.

`scripts/audit-sources.sh` prints the current table (below, as of 2026-10-05).

## Flagged sources and why

| Package | Why authenticity is not established | Way out |
|---|---|---|
| libpng | release files (SourceForge) unsigned; the git tags are signed, but the current key (1FED507E…B292C64843FF5BCF) is published only on GitHub and not certified by the maintainer's keyserver key (F57A5503…C9E384533403C2F8) | maintainer publishes the key on a keyserver or cross-certifies it |
| glib | GNOME's release tarball is not the signed tag's tree (it bundles subprojects); GNOME does not sign tarballs | build from the signed tag with its subprojects pinned |
| pango, fontconfig, tllist, wmenu, seatd, pkgconf, perl | tags are signed, but the keys are not on public keyservers (or the signatures are SSH, which is not checked yet) | find the keys on an independent source; SSH tag signatures |
| json-c, libxkbcommon, tmux, libffi, samurai, vulkan-headers | tags unsigned (vulkan-headers: annotated but not verifiable), releases unsigned | none upstream |
| glslang, fastfetch, wl-clipboard, jq, htop, dwl, vulkan-loader | lightweight tags (cannot be signed), releases unsigned (jq: Sigstore attestation, htop: a SHA256 file on the same host) | Sigstore verification for jq |
| python-mako, -markupsafe, -packaging, -pyyaml | PyPI: no GPG signatures | Sigstore (PEP 740) attestations |
| linux (Alpine config), elfutils (musl patch) | files from Alpine's aports at a pinned commit; the commit's authenticity is not checked | signed aports commits, or cig's own reviewed config (Phase 5) |
| ca-certificates | curl.se's extract of Mozilla's CA store, unsigned | build from Mozilla's certdata at a verified revision |
| lua, mandoc, sinit, tree, mtdev, font-jetbrains-mono, libudev-zero, musl-fts, musl-obstack, argp-standalone | no signature and no independently published checksum | none upstream |

## Current table

| Package | Source host | Authenticity |
|---|---|---|
| argp-standalone | github.com | **UNVERIFIED** (pinned SHA256 only, trusted on first use) |
| autoconf | ftp.gnu.org | upstream GPG signature |
| automake | ftp.gnu.org | upstream GPG signature |
| bash | ftp.gnu.org | upstream GPG signature |
| binutils | ftp.gnu.org | upstream GPG signature |
| bison | ftp.gnu.org | upstream GPG signature |
| busybox | busybox.net | upstream GPG signature |
| ca-certificates | curl.se | **UNVERIFIED** (pinned SHA256 only, trusted on first use) |
| cairo | cairographics.org | signed git tag (archive = tag tree) |
| cmake | github.com | signed checksum file |
| curl | curl.se | upstream GPG signature |
| dwl | codeberg.org | **UNVERIFIED** (pinned SHA256 only, trusted on first use) |
| e2fsprogs | cdn.kernel.org | upstream GPG signature |
| elfutils | sourceware.org | upstream GPG signature |
| elfutils | gitlab.alpinelinux.org | **UNVERIFIED** (pinned SHA256 only, trusted on first use) |
| expat | github.com | upstream GPG signature |
| fastfetch | github.com | **UNVERIFIED** (pinned SHA256 only, trusted on first use) |
| fcft | codeberg.org | signed git tag (archive = tag tree) |
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
| gperf | ftp.gnu.org | upstream GPG signature |
| grim | gitlab.freedesktop.org | upstream GPG signature |
| harfbuzz | github.com | signed git tag (archive = tag tree) |
| htop | github.com | **UNVERIFIED** (pinned SHA256 only, trusted on first use) |
| hwdata | github.com | signed git tag (archive = tag tree) |
| jq | github.com | **UNVERIFIED** (pinned SHA256 only, trusted on first use) |
| json-c | github.com | **UNVERIFIED** (pinned SHA256 only, trusted on first use) |
| less | www.greenwoodsoftware.com | upstream GPG signature |
| libdisplay-info | gitlab.freedesktop.org | signed git tag (archive = tag tree) |
| libdrm | dri.freedesktop.org | upstream GPG signature |
| libevdev | www.freedesktop.org | upstream GPG signature |
| libevent | github.com | upstream GPG signature |
| libffi | github.com | **UNVERIFIED** (pinned SHA256 only, trusted on first use) |
| libinput | gitlab.freedesktop.org | signed git tag (archive = tag tree) |
| libjpeg-turbo | github.com | upstream GPG signature |
| libnl | github.com | upstream GPG signature |
| libpng | github.com | **UNVERIFIED** (pinned SHA256 only, trusted on first use) |
| libtool | ftp.gnu.org | upstream GPG signature |
| libudev-zero | github.com | **UNVERIFIED** (pinned SHA256 only, trusted on first use) |
| libxkbcommon | github.com | **UNVERIFIED** (pinned SHA256 only, trusted on first use) |
| linux-firmware | cdn.kernel.org | upstream GPG signature |
| linux-headers | cdn.kernel.org | upstream GPG signature |
| linux | cdn.kernel.org | upstream GPG signature |
| linux | github.com | upstream GPG signature |
| linux | gitlab.alpinelinux.org | **UNVERIFIED** (pinned SHA256 only, trusted on first use) |
| lua | www.lua.org | **UNVERIFIED** (pinned SHA256 only, trusted on first use) |
| m4 | ftp.gnu.org | upstream GPG signature |
| make | ftp.gnu.org | upstream GPG signature |
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
| opendoas | github.com | upstream GPG signature |
| openssh | cdn.openbsd.org | upstream GPG signature |
| openssl | github.com | upstream GPG signature |
| pango | download.gnome.org | **UNVERIFIED** (pinned SHA256 only, trusted on first use) |
| pcre2 | github.com | upstream GPG signature |
| perl | www.cpan.org | **UNVERIFIED** (pinned SHA256 only, trusted on first use) |
| pixman | www.x.org | signed checksum file |
| pkgconf | distfiles.ariadne.space | **UNVERIFIED** (pinned SHA256 only, trusted on first use) |
| python-mako | files.pythonhosted.org | **UNVERIFIED** (pinned SHA256 only, trusted on first use) |
| python-markupsafe | files.pythonhosted.org | **UNVERIFIED** (pinned SHA256 only, trusted on first use) |
| python-packaging | files.pythonhosted.org | **UNVERIFIED** (pinned SHA256 only, trusted on first use) |
| python-pyyaml | files.pythonhosted.org | **UNVERIFIED** (pinned SHA256 only, trusted on first use) |
| python | www.python.org | upstream GPG signature |
| rsync | download.samba.org | upstream GPG signature |
| samurai | github.com | **UNVERIFIED** (pinned SHA256 only, trusted on first use) |
| seatd | git.sr.ht | **UNVERIFIED** (pinned SHA256 only, trusted on first use) |
| sinit | dl.suckless.org | **UNVERIFIED** (pinned SHA256 only, trusted on first use) |
| slurp | github.com | upstream GPG signature |
| strace | github.com | upstream GPG signature |
| sway | github.com | upstream GPG signature |
| swaybg | github.com | upstream GPG signature |
| tllist | codeberg.org | **UNVERIFIED** (pinned SHA256 only, trusted on first use) |
| tmux | github.com | **UNVERIFIED** (pinned SHA256 only, trusted on first use) |
| tree | oldmanprogrammer.net | **UNVERIFIED** (pinned SHA256 only, trusted on first use) |
| util-linux | cdn.kernel.org | upstream GPG signature |
| vim | github.com | signed git tag (archive = tag tree) |
| vulkan-headers | github.com | **UNVERIFIED** (pinned SHA256 only, trusted on first use) |
| vulkan-loader | github.com | **UNVERIFIED** (pinned SHA256 only, trusted on first use) |
| wayland-protocols | gitlab.freedesktop.org | upstream GPG signature |
| wayland | gitlab.freedesktop.org | upstream GPG signature |
| wl-clipboard | github.com | **UNVERIFIED** (pinned SHA256 only, trusted on first use) |
| wlroots | gitlab.freedesktop.org | upstream GPG signature |
| wmenu | codeberg.org | **UNVERIFIED** (pinned SHA256 only, trusted on first use) |
| wpa_supplicant | w1.fi | upstream GPG signature |
| xkeyboard-config | www.x.org | upstream GPG signature |
| xz | github.com | upstream GPG signature |
| zlib | github.com | upstream GPG signature |
| zstd | github.com | upstream GPG signature |

69 sources verified, 39 flagged.
