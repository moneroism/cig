#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 moneroism
# prepare-wayland.sh - run on the HOST as your normal user (image mounted,
# not inside the chroot). Round A of the graphics phase: everything wlroots
# needs, plus wlroots itself. Downloads + verifies, copies into /mnt/lfs/sources.
#
# Unlike the earlier prepare scripts, this one tries ALL downloads first and
# reports every problem at the end, instead of stopping at the first one.

set -euo pipefail

LFS=/mnt/lfs
STAGE="$HOME/cig/stage/wayland"
GH="$STAGE/.gnupg"

# pinned (compatibility with wlroots 0.19 / dwl 0.8)
WAYLAND_VER=1.24.0
DISPLAYINFO_VER=0.2.0
MTDEV_VER=1.1.7
UDEVZERO_VER=1.0.3
SEATD_VER=0.9.1

die()  { echo; echo "!! $*" >&2; exit 1; }
info() { echo "==> $*"; }
FAILS=()
fail() { echo "   !! $*"; FAILS+=("$*"); }

[ "$(id -u)" -ne 0 ] || die "run as your normal user"
mountpoint -q "$LFS" || die "$LFS is not mounted"
mountpoint -q "$LFS/proc" && die "exit the chroot first"

mkdir -p "$STAGE" "$GH"; chmod 700 "$GH"
cd "$STAGE"
: > SIGNERS.txt

fetch() {   # fetch <url> [name] -> 0 ok / 1 failed (recorded)
    local n=${2:-$(basename "$1")}
    [ -s "$n" ] && return 0
    if wget -q --show-progress -O "$n.part" "$1"; then mv "$n.part" "$n"; return 0; fi
    rm -f "$n.part"; fail "download failed: $1"; return 1
}
fetch_opt() {
    local n=${2:-$(basename "$1")}
    [ -s "$n" ] && return 0
    wget -q -O "$n.part" "$1" 2>/dev/null && mv "$n.part" "$n" && return 0
    rm -f "$n.part"; return 1
}
latest() { wget -qO- "$1" | grep -oE "$2" | sort -uV | tail -n1 || true; }
gl_latest() {   # gl_latest <group%2Fproject> <version regex>; skips x.y.9xx pre-releases
    wget -qO- "https://gitlab.freedesktop.org/api/v4/projects/$1/releases?per_page=50" \
        | grep -oE "\"tag_name\":\"$2\"" | sed 's/.*:"//; s/"//' \
        | awk -F. '$NF < 90' | sort -uV | tail -n1 || true
}

gpgcheck() {
    local out fpr key ks
    out=$(gpg --homedir "$GH" --status-fd 1 --verify "$1" "$2" 2>/dev/null || true)
    if echo "$out" | grep -q NO_PUBKEY; then
        key=$(echo "$out" | awk '/NO_PUBKEY/ {print $3; exit}')
        for ks in hkps://keyserver.ubuntu.com hkps://keys.openpgp.org hkps://pgp.mit.edu; do
            gpg --homedir "$GH" --keyserver "$ks" --recv-keys "$key" >/dev/null 2>&1 && break
        done
        out=$(gpg --homedir "$GH" --status-fd 1 --verify "$1" "$2" 2>/dev/null || true)
    fi
    echo "$out" | grep -q BADSIG && die "BAD SIGNATURE: $2. Delete it and download again."
    fpr=$(echo "$out" | awk '/VALIDSIG/ {print $3; exit}')
    if [ -z "$fpr" ]; then fail "signature check failed (key not found?): $2"; return; fi
    echo "$2  signed by key $fpr" | tee -a SIGNERS.txt
}

# get <tarball-url> [sig-url]: download, verify if a signature exists
get() {
    local t; t=$(basename "$1")
    fetch "$1" || return 0
    if [ -n "${2:-}" ] && fetch_opt "$2"; then
        gpgcheck "$(basename "$2")" "$t"
    else
        echo "$t  no signature published, sha256 trusted on first use" | tee -a SIGNERS.txt
    fi
}

# ---------- versions ----------
info "detecting versions"
LIBFFI_VER=$(latest https://github.com/libffi/libffi/tags 'releases/tag/v3\.[0-9]+\.[0-9]+"' | sed 's#.*/v##; s/"//')
EXPAT_TAG=$(latest https://github.com/libexpat/libexpat/tags 'releases/tag/R_2_[0-9]+_[0-9]+"' | sed 's#.*/##; s/"//')
EXPAT_VER=$(echo "$EXPAT_TAG" | sed 's/^R_//; s/_/./g')
PROTOCOLS_VER=$(gl_latest wayland%2Fwayland-protocols '1\.[0-9]+')
LIBDRM_VER=$(latest https://dri.freedesktop.org/libdrm/ 'libdrm-2\.4\.[0-9]+\.tar\.xz' | sed 's/libdrm-//; s/\.tar\.xz//')
PIXMAN_VER=$(latest https://www.x.org/releases/individual/lib/ 'pixman-0\.[0-9]+\.[0-9]+\.tar\.xz' | sed 's/pixman-//; s/\.tar\.xz//')
XKBCONFIG_VER=$(latest https://www.x.org/releases/individual/data/xkeyboard-config/ 'xkeyboard-config-2\.[0-9]+\.tar\.xz' | sed 's/xkeyboard-config-//; s/\.tar\.xz//')
XKBCOMMON_VER=$(latest https://github.com/xkbcommon/libxkbcommon/tags 'releases/tag/xkbcommon-1\.[0-9]+\.[0-9]+"' | sed 's#.*/xkbcommon-##; s/"//')
LIBEVDEV_VER=$(latest https://www.freedesktop.org/software/libevdev/ 'libevdev-1\.[0-9]+\.[0-9]+\.tar\.xz' | sed 's/libevdev-//; s/\.tar\.xz//')
LIBINPUT_VER=$(gl_latest libinput%2Flibinput '1\.[0-9]+\.[0-9]+')
HWDATA_VER=$(latest https://github.com/vcrhonek/hwdata/tags 'releases/tag/v0\.[0-9]+"' | sed 's#.*/v##; s/"//')
WLROOTS_VER=$(gl_latest wlroots%2Fwlroots '0\.19\.[0-9]+')

for v in LIBFFI_VER EXPAT_VER PROTOCOLS_VER LIBDRM_VER PIXMAN_VER XKBCONFIG_VER \
         XKBCOMMON_VER LIBEVDEV_VER LIBINPUT_VER HWDATA_VER WLROOTS_VER; do
    [ -n "${!v}" ] || fail "could not detect $v"
done
[ ${#FAILS[@]} -eq 0 ] || die "version detection failed: ${FAILS[*]}"

cat <<EOF
   libffi $LIBFFI_VER, expat $EXPAT_VER, wayland $WAYLAND_VER, protocols $PROTOCOLS_VER
   libdrm $LIBDRM_VER, pixman $PIXMAN_VER, xkeyboard-config $XKBCONFIG_VER, xkbcommon $XKBCOMMON_VER
   mtdev $MTDEV_VER, libevdev $LIBEVDEV_VER, libudev-zero $UDEVZERO_VER, libinput $LIBINPUT_VER
   seatd $SEATD_VER, hwdata $HWDATA_VER, libdisplay-info $DISPLAYINFO_VER, wlroots $WLROOTS_VER
EOF

# ---------- downloads ----------
FD=https://gitlab.freedesktop.org
info "downloading and verifying"
get "https://github.com/libffi/libffi/releases/download/v$LIBFFI_VER/libffi-$LIBFFI_VER.tar.gz"
get "https://github.com/libexpat/libexpat/releases/download/$EXPAT_TAG/expat-$EXPAT_VER.tar.xz" \
    "https://github.com/libexpat/libexpat/releases/download/$EXPAT_TAG/expat-$EXPAT_VER.tar.xz.asc"
get "$FD/wayland/wayland/-/releases/$WAYLAND_VER/downloads/wayland-$WAYLAND_VER.tar.xz" \
    "$FD/wayland/wayland/-/releases/$WAYLAND_VER/downloads/wayland-$WAYLAND_VER.tar.xz.sig"
get "$FD/wayland/wayland-protocols/-/releases/$PROTOCOLS_VER/downloads/wayland-protocols-$PROTOCOLS_VER.tar.xz" \
    "$FD/wayland/wayland-protocols/-/releases/$PROTOCOLS_VER/downloads/wayland-protocols-$PROTOCOLS_VER.tar.xz.sig"
get "https://dri.freedesktop.org/libdrm/libdrm-$LIBDRM_VER.tar.xz" \
    "https://dri.freedesktop.org/libdrm/libdrm-$LIBDRM_VER.tar.xz.sig"
get "https://www.x.org/releases/individual/lib/pixman-$PIXMAN_VER.tar.xz" \
    "https://www.x.org/releases/individual/lib/pixman-$PIXMAN_VER.tar.xz.sig"
get "https://www.x.org/releases/individual/data/xkeyboard-config/xkeyboard-config-$XKBCONFIG_VER.tar.xz" \
    "https://www.x.org/releases/individual/data/xkeyboard-config/xkeyboard-config-$XKBCONFIG_VER.tar.xz.sig"
get "https://github.com/xkbcommon/libxkbcommon/archive/refs/tags/xkbcommon-$XKBCOMMON_VER.tar.gz" \
    && [ -s "xkbcommon-$XKBCOMMON_VER.tar.gz" ] \
    && mv -f "xkbcommon-$XKBCOMMON_VER.tar.gz" "libxkbcommon-$XKBCOMMON_VER.tar.gz" || true
get "https://bitmath.org/code/mtdev/mtdev-$MTDEV_VER.tar.bz2"
get "https://www.freedesktop.org/software/libevdev/libevdev-$LIBEVDEV_VER.tar.xz" \
    "https://www.freedesktop.org/software/libevdev/libevdev-$LIBEVDEV_VER.tar.xz.sig"
get "https://github.com/illiliti/libudev-zero/archive/refs/tags/$UDEVZERO_VER.tar.gz" \
    && [ -s "$UDEVZERO_VER.tar.gz" ] && mv -f "$UDEVZERO_VER.tar.gz" "libudev-zero-$UDEVZERO_VER.tar.gz" || true
get "$FD/libinput/libinput/-/archive/$LIBINPUT_VER/libinput-$LIBINPUT_VER.tar.gz"
get "https://git.sr.ht/~kennylevinsen/seatd/archive/$SEATD_VER.tar.gz" \
    && [ -s "$SEATD_VER.tar.gz" ] && mv -f "$SEATD_VER.tar.gz" "seatd-$SEATD_VER.tar.gz" || true
get "https://github.com/vcrhonek/hwdata/archive/refs/tags/v$HWDATA_VER.tar.gz" \
    && [ -s "v$HWDATA_VER.tar.gz" ] && mv -f "v$HWDATA_VER.tar.gz" "hwdata-$HWDATA_VER.tar.gz" || true
get "$FD/emersion/libdisplay-info/-/releases/$DISPLAYINFO_VER/downloads/libdisplay-info-$DISPLAYINFO_VER.tar.xz" \
    "$FD/emersion/libdisplay-info/-/releases/$DISPLAYINFO_VER/downloads/libdisplay-info-$DISPLAYINFO_VER.tar.xz.sig"
get "$FD/wlroots/wlroots/-/releases/$WLROOTS_VER/downloads/wlroots-$WLROOTS_VER.tar.gz" \
    "$FD/wlroots/wlroots/-/releases/$WLROOTS_VER/downloads/wlroots-$WLROOTS_VER.tar.gz.sig"

if [ ${#FAILS[@]} -gt 0 ]; then
    echo
    echo "!! problems:"
    printf '   - %s\n' "${FAILS[@]}"
    die "nothing was copied. Paste the list above."
fi

# ---------- copy into the system ----------
info "copying into $LFS/sources (sudo)"
FILES=(
  "libffi-$LIBFFI_VER.tar.gz" "expat-$EXPAT_VER.tar.xz" "wayland-$WAYLAND_VER.tar.xz"
  "wayland-protocols-$PROTOCOLS_VER.tar.xz" "libdrm-$LIBDRM_VER.tar.xz" "pixman-$PIXMAN_VER.tar.xz"
  "xkeyboard-config-$XKBCONFIG_VER.tar.xz" "libxkbcommon-$XKBCOMMON_VER.tar.gz"
  "mtdev-$MTDEV_VER.tar.bz2" "libevdev-$LIBEVDEV_VER.tar.xz" "libudev-zero-$UDEVZERO_VER.tar.gz"
  "libinput-$LIBINPUT_VER.tar.gz" "seatd-$SEATD_VER.tar.gz" "hwdata-$HWDATA_VER.tar.gz"
  "libdisplay-info-$DISPLAYINFO_VER.tar.xz" "wlroots-$WLROOTS_VER.tar.gz"
)
for f in "${FILES[@]}"; do
    sudo install -m 644 "$f" "$LFS/sources/$f"
    sha256sum "$f" | sudo tee -a "$LFS/sources/SHA256SUMS" >/dev/null
done
sudo install -m 644 SIGNERS.txt "$LFS/sources/SIGNERS-wayland.txt"
HERE="$(cd "$(dirname "$0")" && pwd)"
[ -f "$HERE/build-wayland.sh" ] && sudo install -m 755 "$HERE/build-wayland.sh" "$LFS/sources/"

VARS="LIBFFI EXPAT WAYLAND PROTOCOLS LIBDRM PIXMAN XKBCONFIG XKBCOMMON MTDEV LIBEVDEV UDEVZERO LIBINPUT SEATD HWDATA DISPLAYINFO WLROOTS"
for v in $VARS; do sudo sed -i "/^${v}_VER=/d" "$LFS/sources/VERSIONS"; done
for v in $VARS; do n="${v}_VER"; echo "$n=${!n}"; done | sudo tee -a "$LFS/sources/VERSIONS" >/dev/null

echo
info "All downloaded. Signers / trust-on-first-use list: $STAGE/SIGNERS.txt"
info "Next: sudo ~/cig/scripts/enter-chroot.sh   then   bash /sources/build-wayland.sh"
