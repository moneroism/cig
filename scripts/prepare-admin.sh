#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 moneroism
# prepare-admin.sh - run on the HOST as your normal user (image mounted,
# not inside the chroot). Fetches OpenDoas and copies build-admin.sh in.

set -euo pipefail

LFS=/mnt/lfs
STAGE="$HOME/cig/stage/admin"
GH="$STAGE/.gnupg"

die()  { echo; echo "!! $*" >&2; exit 1; }
info() { echo "==> $*"; }

[ "$(id -u)" -ne 0 ] || die "run as your normal user"
mountpoint -q "$LFS" || die "$LFS is not mounted"
mountpoint -q "$LFS/proc" && die "exit the chroot first"
mkdir -p "$STAGE" "$GH"; chmod 700 "$GH"
cd "$STAGE"
: > SIGNERS.txt

latest() { wget -qO- "$1" | grep -oE "$2" | sort -uV | tail -n1 || true; }

DOAS_VER=$(latest https://github.com/Duncaen/OpenDoas/tags 'releases/tag/v6\.[0-9]+\.[0-9]+"' | sed 's#.*/v##; s/"//')
[ -n "$DOAS_VER" ] || die "could not detect the OpenDoas version"
info "OpenDoas $DOAS_VER"

T="opendoas-$DOAS_VER.tar.xz"
URL="https://github.com/Duncaen/OpenDoas/releases/download/v$DOAS_VER/$T"
[ -s "$T" ] || wget -q --show-progress -O "$T" "$URL" || die "download failed: $URL"

if wget -q -O "$T.sig" "$URL.sig" 2>/dev/null; then
    out=$(gpg --homedir "$GH" --status-fd 1 --verify "$T.sig" "$T" 2>/dev/null || true)
    if echo "$out" | grep -q NO_PUBKEY; then
        key=$(echo "$out" | awk '/NO_PUBKEY/ {print $3; exit}')
        for ks in hkps://keyserver.ubuntu.com hkps://keys.openpgp.org; do
            gpg --homedir "$GH" --keyserver "$ks" --recv-keys "$key" >/dev/null 2>&1 && break
        done
        out=$(gpg --homedir "$GH" --status-fd 1 --verify "$T.sig" "$T" 2>/dev/null || true)
    fi
    echo "$out" | grep -q BADSIG && die "BAD SIGNATURE: $T"
    fpr=$(echo "$out" | awk '/VALIDSIG/ {print $3; exit}')
    [ -n "$fpr" ] || die "signature check failed: $T"
    echo "$T  signed by key $fpr" | tee -a SIGNERS.txt
else
    rm -f "$T.sig"
    echo "$T  no signature published, sha256 trusted on first use" | tee -a SIGNERS.txt
fi

info "copying into $LFS/sources (sudo)"
sudo install -m 644 "$T" "$LFS/sources/$T"
sha256sum "$T" | sudo tee -a "$LFS/sources/SHA256SUMS" >/dev/null
sudo install -m 644 SIGNERS.txt "$LFS/sources/SIGNERS-admin.txt"
HERE="$(cd "$(dirname "$0")" && pwd)"
[ -f "$HERE/build-admin.sh" ] && sudo install -m 755 "$HERE/build-admin.sh" "$LFS/sources/"
sudo sed -i '/^DOAS_VER=/d' "$LFS/sources/VERSIONS"
echo "DOAS_VER=$DOAS_VER" | sudo tee -a "$LFS/sources/VERSIONS" >/dev/null

info "Next: sudo ~/cig/scripts/enter-chroot.sh   then   bash /sources/build-admin.sh"
