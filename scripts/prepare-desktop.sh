#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 moneroism
# prepare-desktop.sh - run on the HOST as your normal user (image mounted,
# not inside the chroot). Round B of the graphics phase: fonts, foot,
# fuzzel, dwl. Tries all downloads, reports every problem at the end.

set -euo pipefail

LFS=/mnt/lfs
STAGE="$HOME/cig/stage/desktop"
GH="$STAGE/.gnupg"

# dwl 0.8 is the release built for wlroots 0.19. Its tarball is unsigned;
# this checksum comes from an independent source (Arch AUR package for 0.8).
DWL_VER=0.8
DWL_SHA256=ccc8bbb3fb66a7e6f0392693533ac9c8bd4e6283dd1f66992e68ec4d4a9cdee7

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

fetch() {
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
cb_latest() {   # cb_latest <owner/repo>: newest release tag on Codeberg
    wget -qO- "https://codeberg.org/api/v1/repos/$1/releases?limit=20" \
        | grep -oE '"tag_name":"v?[0-9]+\.[0-9]+(\.[0-9]+)?"' \
        | sed 's/.*:"//; s/"//; s/^v//' | sort -uV | tail -n1 || true
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

# get <url> [sig-url] [save-as]
get() {
    local t=${3:-$(basename "$1")}
    fetch "$1" "$t" || return 0
    if [ -n "${2:-}" ] && fetch_opt "$2"; then
        gpgcheck "$(basename "$2")" "$t"
    else
        echo "$t  no signature published, sha256 trusted on first use" | tee -a SIGNERS.txt
    fi
}

# ---------- versions ----------
info "detecting versions"
GPERF_VER=$(latest https://ftp.gnu.org/gnu/gperf/ 'gperf-[0-9]+\.[0-9]+(\.[0-9]+)?\.tar\.gz' | sed 's/gperf-//; s/\.tar\.gz//')
FREETYPE_VER=$(latest https://download.savannah.gnu.org/releases/freetype/ 'freetype-2\.[0-9]+\.[0-9]+\.tar\.xz' | sed 's/freetype-//; s/\.tar\.xz//')
FONTCONFIG_VER=$(latest https://www.freedesktop.org/software/fontconfig/release/ 'fontconfig-2\.[0-9]+\.[0-9]+\.tar\.xz' | sed 's/fontconfig-//; s/\.tar\.xz//')
JBMONO_VER=$(latest https://github.com/JetBrains/JetBrainsMono/tags 'releases/tag/v2\.[0-9]+"' | sed 's#.*/v##; s/"//')
TLLIST_VER=$(cb_latest dnkl/tllist)
FCFT_VER=$(cb_latest dnkl/fcft)
FOOT_VER=$(cb_latest dnkl/foot)
FUZZEL_VER=$(cb_latest dnkl/fuzzel)

for v in GPERF_VER FREETYPE_VER FONTCONFIG_VER JBMONO_VER TLLIST_VER FCFT_VER FOOT_VER FUZZEL_VER; do
    [ -n "${!v}" ] || fail "could not detect $v"
done
[ ${#FAILS[@]} -eq 0 ] || die "version detection failed: ${FAILS[*]}"

cat <<EOF
   gperf $GPERF_VER, freetype $FREETYPE_VER, fontconfig $FONTCONFIG_VER, JetBrains Mono $JBMONO_VER
   tllist $TLLIST_VER, fcft $FCFT_VER, foot $FOOT_VER, fuzzel $FUZZEL_VER, dwl $DWL_VER
EOF

# ---------- downloads ----------
info "downloading and verifying"
get "https://ftp.gnu.org/gnu/gperf/gperf-$GPERF_VER.tar.gz" \
    "https://ftp.gnu.org/gnu/gperf/gperf-$GPERF_VER.tar.gz.sig"
get "https://download.savannah.gnu.org/releases/freetype/freetype-$FREETYPE_VER.tar.xz" \
    "https://download.savannah.gnu.org/releases/freetype/freetype-$FREETYPE_VER.tar.xz.sig"
get "https://www.freedesktop.org/software/fontconfig/release/fontconfig-$FONTCONFIG_VER.tar.xz" \
    "https://www.freedesktop.org/software/fontconfig/release/fontconfig-$FONTCONFIG_VER.tar.xz.sig"
get "https://github.com/JetBrains/JetBrainsMono/releases/download/v$JBMONO_VER/JetBrainsMono-$JBMONO_VER.zip"
get "https://codeberg.org/dnkl/tllist/archive/$TLLIST_VER.tar.gz" "" "tllist-$TLLIST_VER.tar.gz"
get "https://codeberg.org/dnkl/fcft/archive/$FCFT_VER.tar.gz" "" "fcft-$FCFT_VER.tar.gz"
get "https://codeberg.org/dnkl/foot/archive/$FOOT_VER.tar.gz" "" "foot-$FOOT_VER.tar.gz"
get "https://codeberg.org/dnkl/fuzzel/archive/$FUZZEL_VER.tar.gz" "" "fuzzel-$FUZZEL_VER.tar.gz"

info "dwl $DWL_VER (checked against a pinned checksum)"
if fetch "https://codeberg.org/dwl/dwl/releases/download/v$DWL_VER/dwl-v$DWL_VER.tar.gz"; then
    if [ "$(sha256sum "dwl-v$DWL_VER.tar.gz" | cut -d' ' -f1)" = "$DWL_SHA256" ]; then
        echo "dwl-v$DWL_VER.tar.gz  sha256 matches pinned value" | tee -a SIGNERS.txt
    else
        fail "CHECKSUM MISMATCH: dwl-v$DWL_VER.tar.gz (delete it and retry; if it persists, stop)"
    fi
fi

if [ ${#FAILS[@]} -gt 0 ]; then
    echo; echo "!! problems:"; printf '   - %s\n' "${FAILS[@]}"
    die "nothing was copied. Paste the list above."
fi

# ---------- copy into the system ----------
info "copying into $LFS/sources (sudo)"
FILES=(
  "gperf-$GPERF_VER.tar.gz" "freetype-$FREETYPE_VER.tar.xz" "fontconfig-$FONTCONFIG_VER.tar.xz"
  "JetBrainsMono-$JBMONO_VER.zip" "tllist-$TLLIST_VER.tar.gz" "fcft-$FCFT_VER.tar.gz"
  "foot-$FOOT_VER.tar.gz" "fuzzel-$FUZZEL_VER.tar.gz" "dwl-v$DWL_VER.tar.gz"
)
for f in "${FILES[@]}"; do
    sudo install -m 644 "$f" "$LFS/sources/$f"
    sha256sum "$f" | sudo tee -a "$LFS/sources/SHA256SUMS" >/dev/null
done
sudo install -m 644 SIGNERS.txt "$LFS/sources/SIGNERS-desktop.txt"
HERE="$(cd "$(dirname "$0")" && pwd)"
[ -f "$HERE/build-desktop.sh" ] && sudo install -m 755 "$HERE/build-desktop.sh" "$LFS/sources/"

VARS="GPERF FREETYPE FONTCONFIG JBMONO TLLIST FCFT FOOT FUZZEL DWL"
for v in $VARS; do sudo sed -i "/^${v}_VER=/d" "$LFS/sources/VERSIONS"; done
for v in $VARS; do n="${v}_VER"; echo "$n=${!n}"; done | sudo tee -a "$LFS/sources/VERSIONS" >/dev/null

echo
info "All downloaded. Signers / trust-on-first-use list: $STAGE/SIGNERS.txt"
info "Next: sudo ~/cig/scripts/enter-chroot.sh   then   bash /sources/build-desktop.sh"
