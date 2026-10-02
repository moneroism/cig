#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 moneroism
# prepare-essentials.sh - run on VOID as your normal user (image mounted,
# not inside the chroot). Downloads + verifies sources for the essentials
# phase and copies them into /mnt/lfs/sources.
#
# Version policy:
#   pinned:       zlib, wpa_supplicant, libnl
#   newest patch: OpenSSL 3.5.x (LTS), e2fsprogs 1.47.x
#   newest:       curl, git, perl (stable)

set -euo pipefail

LFS=/mnt/lfs
STAGE="$HOME/cig/stage/essentials"
GH="$STAGE/.gnupg"
KEYSERVER=hkps://keyserver.ubuntu.com

ZLIB_VER=1.3.1
WPA_VER=2.11
LIBNL_VER=3.11.0
FLEX_VER=2.6.4

die()  { echo; echo "!! $*" >&2; exit 1; }
info() { echo "==> $*"; }

[ "$(id -u)" -ne 0 ] || die "run as your normal user"
mountpoint -q "$LFS" || die "$LFS is not mounted"
mountpoint -q "$LFS/proc" && die "exit the chroot first"
for c in wget gpg sha256sum xz sort; do command -v $c >/dev/null || die "missing: $c"; done

mkdir -p "$STAGE" "$GH"; chmod 700 "$GH"
cd "$STAGE"
: > SIGNERS.txt

fetch() {  # fetch <url> [name]
    local n=${2:-$(basename "$1")}
    [ -s "$n" ] && return
    wget -q --show-progress -O "$n.part" "$1" || { rm -f "$n.part"; die "download failed: $1"; }
    mv "$n.part" "$n"
}

latest() {  # latest <url> <regex>  -> newest match, version-sorted
    wget -qO- "$1" | grep -oE "$2" | sort -uV | tail -n1 || true
}

gpgcheck() {  # gpgcheck <sigfile> <datafile> [label]
    local out fpr key ks
    out=$(gpg --homedir "$GH" --status-fd 1 --verify "$1" "$2" 2>/dev/null || true)
    if echo "$out" | grep -q 'NO_PUBKEY'; then
        key=$(echo "$out" | awk '/NO_PUBKEY/ {print $3; exit}')
        for ks in hkps://keyserver.ubuntu.com hkps://keys.openpgp.org hkps://pgp.mit.edu; do
            gpg --homedir "$GH" --keyserver "$ks" --recv-keys "$key" >/dev/null 2>&1 && break
        done
        out=$(gpg --homedir "$GH" --status-fd 1 --verify "$1" "$2" 2>/dev/null || true)
    fi
    echo "$out" | grep -q 'BADSIG' && die "BAD SIGNATURE: ${3:-$2}. Delete it and download again."
    echo "$out" | grep -q 'NO_PUBKEY' && die "signing key $key for ${3:-$2} not found on any keyserver"
    fpr=$(echo "$out" | awk '/VALIDSIG/ {print $3; exit}')
    [ -n "$fpr" ] || die "SIGNATURE CHECK FAILED: ${3:-$2}"
    echo "${3:-$2}  signed by key $fpr" | tee -a SIGNERS.txt
}

# ---------- versions ----------
info "detecting versions"
OPENSSL_VER=$(latest https://github.com/openssl/openssl/tags 'openssl-3\.5\.[0-9]+' | sed 's/openssl-//')
CURL_VER=$(latest https://curl.se/download/ 'curl-[0-9]+\.[0-9]+\.[0-9]+\.tar\.xz' | sed 's/curl-//; s/\.tar\.xz//')
# git 2.x only: git 3.0 makes Rust mandatory
GIT_VER=$(latest https://cdn.kernel.org/pub/software/scm/git/ 'git-2\.[0-9]+\.[0-9]+\.tar\.xz' | sed 's/git-//; s/\.tar\.xz//')
E2FS_VER=$(latest https://cdn.kernel.org/pub/linux/kernel/people/tytso/e2fsprogs/ 'v1\.47\.[0-9]+' | sed 's/^v//')
PERL_VER=$(latest https://www.cpan.org/src/5.0/ 'perl-5\.[0-9]*[02468]\.[0-9]+\.tar\.xz' | sed 's/perl-//; s/\.tar\.xz//')
BISON_VER=$(latest https://ftp.gnu.org/gnu/bison/ 'bison-[0-9]+\.[0-9]+(\.[0-9]+)?\.tar\.xz' | sed 's/bison-//; s/\.tar\.xz//')
for v in OPENSSL_VER CURL_VER GIT_VER E2FS_VER PERL_VER BISON_VER; do
    [ -n "${!v}" ] || die "could not detect $v"
done
info "zlib $ZLIB_VER, e2fsprogs $E2FS_VER, perl $PERL_VER, openssl $OPENSSL_VER,"
info "curl $CURL_VER, git $GIT_VER, libnl $LIBNL_VER, wpa_supplicant $WPA_VER"

# ---------- downloads + verification ----------
info "zlib"
fetch "https://github.com/madler/zlib/releases/download/v$ZLIB_VER/zlib-$ZLIB_VER.tar.gz"
fetch "https://github.com/madler/zlib/releases/download/v$ZLIB_VER/zlib-$ZLIB_VER.tar.gz.asc"
gpgcheck "zlib-$ZLIB_VER.tar.gz.asc" "zlib-$ZLIB_VER.tar.gz"

info "e2fsprogs"
fetch "https://cdn.kernel.org/pub/linux/kernel/people/tytso/e2fsprogs/v$E2FS_VER/e2fsprogs-$E2FS_VER.tar.xz"
fetch "https://cdn.kernel.org/pub/linux/kernel/people/tytso/e2fsprogs/v$E2FS_VER/e2fsprogs-$E2FS_VER.tar.sign"
xz -dc "e2fsprogs-$E2FS_VER.tar.xz" > "e2fsprogs-$E2FS_VER.tar"
gpgcheck "e2fsprogs-$E2FS_VER.tar.sign" "e2fsprogs-$E2FS_VER.tar" "e2fsprogs-$E2FS_VER.tar.xz"
rm -f "e2fsprogs-$E2FS_VER.tar"

info "perl (no signatures upstream: checked against cpan.org's published sha256)"
fetch "https://www.cpan.org/src/5.0/perl-$PERL_VER.tar.xz"
fetch "https://www.cpan.org/src/5.0/perl-$PERL_VER.tar.xz.sha256.txt"
[ "$(sha256sum "perl-$PERL_VER.tar.xz" | cut -d' ' -f1)" = "$(tr -d ' \n' < "perl-$PERL_VER.tar.xz.sha256.txt")" ] \
    || die "CHECKSUM MISMATCH: perl"
echo "perl-$PERL_VER.tar.xz  sha256 matches cpan.org (no signature)" | tee -a SIGNERS.txt

info "openssl"
fetch "https://github.com/openssl/openssl/releases/download/openssl-$OPENSSL_VER/openssl-$OPENSSL_VER.tar.gz"
fetch "https://github.com/openssl/openssl/releases/download/openssl-$OPENSSL_VER/openssl-$OPENSSL_VER.tar.gz.asc"
gpgcheck "openssl-$OPENSSL_VER.tar.gz.asc" "openssl-$OPENSSL_VER.tar.gz"

info "CA certificates (Mozilla bundle, via curl.se)"
fetch https://curl.se/ca/cacert.pem
fetch https://curl.se/ca/cacert.pem.sha256
sha256sum -c cacert.pem.sha256 >/dev/null || die "CHECKSUM MISMATCH: cacert.pem"
echo "cacert.pem  sha256 matches curl.se (no signature)" | tee -a SIGNERS.txt

info "curl"
fetch "https://curl.se/download/curl-$CURL_VER.tar.xz"
fetch "https://curl.se/download/curl-$CURL_VER.tar.xz.asc"
gpgcheck "curl-$CURL_VER.tar.xz.asc" "curl-$CURL_VER.tar.xz"

info "git"
fetch "https://cdn.kernel.org/pub/software/scm/git/git-$GIT_VER.tar.xz"
fetch "https://cdn.kernel.org/pub/software/scm/git/git-$GIT_VER.tar.sign"
xz -dc "git-$GIT_VER.tar.xz" > "git-$GIT_VER.tar"
gpgcheck "git-$GIT_VER.tar.sign" "git-$GIT_VER.tar" "git-$GIT_VER.tar.xz"
rm -f "git-$GIT_VER.tar"

info "bison"
fetch "https://ftp.gnu.org/gnu/bison/bison-$BISON_VER.tar.xz"
fetch "https://ftp.gnu.org/gnu/bison/bison-$BISON_VER.tar.xz.sig"
gpgcheck "bison-$BISON_VER.tar.xz.sig" "bison-$BISON_VER.tar.xz"

info "flex"
fetch "https://github.com/westes/flex/releases/download/v$FLEX_VER/flex-$FLEX_VER.tar.gz"
fetch "https://github.com/westes/flex/releases/download/v$FLEX_VER/flex-$FLEX_VER.tar.gz.sig"
gpgcheck "flex-$FLEX_VER.tar.gz.sig" "flex-$FLEX_VER.tar.gz"

info "libnl (no signatures upstream: sha256 recorded on first download)"
LIBNL_TAG="libnl$(echo "$LIBNL_VER" | tr . _)"
fetch "https://github.com/thom311/libnl/releases/download/$LIBNL_TAG/libnl-$LIBNL_VER.tar.gz"
echo "libnl-$LIBNL_VER.tar.gz  no signature, sha256 trusted on first use" | tee -a SIGNERS.txt

info "wpa_supplicant"
fetch "https://w1.fi/releases/wpa_supplicant-$WPA_VER.tar.gz"
fetch "https://w1.fi/releases/wpa_supplicant-$WPA_VER.tar.gz.asc"
gpgcheck "wpa_supplicant-$WPA_VER.tar.gz.asc" "wpa_supplicant-$WPA_VER.tar.gz"

# ---------- copy into the system ----------
info "copying into $LFS/sources (sudo)"
for f in "zlib-$ZLIB_VER.tar.gz" "e2fsprogs-$E2FS_VER.tar.xz" "perl-$PERL_VER.tar.xz" \
         "openssl-$OPENSSL_VER.tar.gz" cacert.pem "curl-$CURL_VER.tar.xz" \
         "git-$GIT_VER.tar.xz" "libnl-$LIBNL_VER.tar.gz" "wpa_supplicant-$WPA_VER.tar.gz" \
         "bison-$BISON_VER.tar.xz" "flex-$FLEX_VER.tar.gz"; do
    sudo install -m 644 "$f" "$LFS/sources/$f"
    sha256sum "$f" | sudo tee -a "$LFS/sources/SHA256SUMS" >/dev/null
done
sudo install -m 644 SIGNERS.txt "$LFS/sources/SIGNERS-essentials.txt"
HERE="$(cd "$(dirname "$0")" && pwd)"
[ -f "$HERE/build-essentials.sh" ] && sudo install -m 755 "$HERE/build-essentials.sh" "$LFS/sources/"

sudo sed -i '/^\(ZLIB\|E2FS\|PERL\|OPENSSL\|CURL\|GIT\|LIBNL\|WPA\|BISON\|FLEX\)_VER=/d' "$LFS/sources/VERSIONS"
cat <<EOF | sudo tee -a "$LFS/sources/VERSIONS" >/dev/null
BISON_VER=$BISON_VER
FLEX_VER=$FLEX_VER
ZLIB_VER=$ZLIB_VER
E2FS_VER=$E2FS_VER
PERL_VER=$PERL_VER
OPENSSL_VER=$OPENSSL_VER
CURL_VER=$CURL_VER
GIT_VER=$GIT_VER
LIBNL_VER=$LIBNL_VER
WPA_VER=$WPA_VER
EOF

echo
info "All verified. Signer fingerprints: $STAGE/SIGNERS.txt"
info "Next: sudo ~/cig/scripts/enter-chroot.sh   then   bash /sources/build-essentials.sh"
