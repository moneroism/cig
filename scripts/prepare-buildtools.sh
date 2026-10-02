#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 moneroism
# prepare-buildtools.sh - run on the HOST as your normal user (image mounted,
# not inside the chroot). Downloads + verifies pkgconf, samurai, Python, meson
# and copies them into /mnt/lfs/sources.
#
# Version policy:
#   pinned:       samurai 1.2
#   newest patch: Python 3.13.x (last GPG-signed series)
#   newest:       meson (stable), pkgconf 2.x

set -euo pipefail

LFS=/mnt/lfs
STAGE="$HOME/cig/stage/buildtools"
GH="$STAGE/.gnupg"
SAMU_VER=1.2

die()  { echo; echo "!! $*" >&2; exit 1; }
info() { echo "==> $*"; }

[ "$(id -u)" -ne 0 ] || die "run as your normal user"
mountpoint -q "$LFS" || die "$LFS is not mounted"
mountpoint -q "$LFS/proc" && die "exit the chroot first"

mkdir -p "$STAGE" "$GH"; chmod 700 "$GH"
cd "$STAGE"
: > SIGNERS.txt

fetch() {
    local n=${2:-$(basename "$1")}
    [ -s "$n" ] && return
    wget -q --show-progress -O "$n.part" "$1" || { rm -f "$n.part"; die "download failed: $1"; }
    mv "$n.part" "$n"
}
fetch_opt() {   # like fetch, but a missing file is not an error
    local n=${2:-$(basename "$1")}
    [ -s "$n" ] && return 0
    wget -q -O "$n.part" "$1" 2>/dev/null && mv "$n.part" "$n" && return 0
    rm -f "$n.part"; return 1
}
latest() { wget -qO- "$1" | grep -oE "$2" | sort -uV | tail -n1 || true; }

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
    echo "$out" | grep -q NO_PUBKEY && die "signing key $key for $2 not found on any keyserver"
    fpr=$(echo "$out" | awk '/VALIDSIG/ {print $3; exit}')
    [ -n "$fpr" ] || die "SIGNATURE CHECK FAILED: $2"
    echo "$2  signed by key $fpr" | tee -a SIGNERS.txt
}

# ---------- versions ----------
info "detecting versions"
PY_VER=$(latest https://www.python.org/ftp/python/ '3\.13\.[0-9]+/' | tr -d /)
MESON_VER=$(latest https://github.com/mesonbuild/meson/tags 'releases/tag/1\.[0-9]+\.[0-9]+"' \
            | sed 's#releases/tag/##; s/"//')
PKGCONF_VER=$(latest https://github.com/pkgconf/pkgconf/tags 'pkgconf-2\.[0-9]+\.[0-9]+"' \
            | sed 's/pkgconf-//; s/"//')
for v in PY_VER MESON_VER PKGCONF_VER; do [ -n "${!v}" ] || die "could not detect $v"; done
info "pkgconf $PKGCONF_VER, samurai $SAMU_VER, Python $PY_VER, meson $MESON_VER"

# ---------- downloads + verification ----------
info "pkgconf"
fetch "https://distfiles.ariadne.space/pkgconf/pkgconf-$PKGCONF_VER.tar.xz"
if fetch_opt "https://distfiles.ariadne.space/pkgconf/pkgconf-$PKGCONF_VER.tar.xz.asc"; then
    gpgcheck "pkgconf-$PKGCONF_VER.tar.xz.asc" "pkgconf-$PKGCONF_VER.tar.xz"
else
    echo "pkgconf-$PKGCONF_VER.tar.xz  no signature published, sha256 trusted on first use" | tee -a SIGNERS.txt
fi

info "samurai"
fetch "https://github.com/michaelforney/samurai/releases/download/$SAMU_VER/samurai-$SAMU_VER.tar.gz"
echo "samurai-$SAMU_VER.tar.gz  no signature published, sha256 trusted on first use" | tee -a SIGNERS.txt

info "Python"
fetch "https://www.python.org/ftp/python/$PY_VER/Python-$PY_VER.tar.xz"
fetch "https://www.python.org/ftp/python/$PY_VER/Python-$PY_VER.tar.xz.asc"
gpgcheck "Python-$PY_VER.tar.xz.asc" "Python-$PY_VER.tar.xz"

info "meson"
fetch "https://github.com/mesonbuild/meson/releases/download/$MESON_VER/meson-$MESON_VER.tar.gz"
fetch "https://github.com/mesonbuild/meson/releases/download/$MESON_VER/meson-$MESON_VER.tar.gz.asc"
gpgcheck "meson-$MESON_VER.tar.gz.asc" "meson-$MESON_VER.tar.gz"

# ---------- copy into the system ----------
info "copying into $LFS/sources (sudo)"
for f in "pkgconf-$PKGCONF_VER.tar.xz" "samurai-$SAMU_VER.tar.gz" \
         "Python-$PY_VER.tar.xz" "meson-$MESON_VER.tar.gz"; do
    sudo install -m 644 "$f" "$LFS/sources/$f"
    sha256sum "$f" | sudo tee -a "$LFS/sources/SHA256SUMS" >/dev/null
done
sudo install -m 644 SIGNERS.txt "$LFS/sources/SIGNERS-buildtools.txt"
HERE="$(cd "$(dirname "$0")" && pwd)"
[ -f "$HERE/build-buildtools.sh" ] && sudo install -m 755 "$HERE/build-buildtools.sh" "$LFS/sources/"

sudo sed -i '/^\(PKGCONF\|SAMU\|PY\|MESON\)_VER=/d' "$LFS/sources/VERSIONS"
cat <<EOF | sudo tee -a "$LFS/sources/VERSIONS" >/dev/null
PKGCONF_VER=$PKGCONF_VER
SAMU_VER=$SAMU_VER
PY_VER=$PY_VER
MESON_VER=$MESON_VER
EOF

echo
info "All verified. Signer fingerprints: $STAGE/SIGNERS.txt"
info "Next: sudo ~/cig/scripts/enter-chroot.sh   then   bash /sources/build-buildtools.sh"
