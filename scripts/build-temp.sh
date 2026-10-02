#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 moneroism
# build-temp.sh - phase 2: temporary system for the hardened distro
#
# Cross-compiles into /mnt/lfs, using the toolchain from build-toolchain.sh:
#   m4, make, gawk, BusyBox, bash, binutils (native), gcc (native)
# Afterwards /mnt/lfs can be entered with enter-chroot.sh and the distro
# builds itself from then on.
#
# Run as your NORMAL user, after build-toolchain.sh has finished.
# Safe to re-run: finished steps are skipped, a failed step restarts.

set -euo pipefail

# ---------------- settings ----------------
LFS=/mnt/lfs
LFS_TGT=x86_64-lfs-linux-musl
BUSYBOX_VER=1.36.1     # newest release busybox.net marks stable
GAWK_VER=5.3.2         # 5.4.x breaks GCC 16's option generator (opt-gather.awk)
# m4, make, bash: newest GNU releases, detected once and pinned
# ------------------------------------------

if [ -z "${LFS_CLEAN_ENV:-}" ]; then
    exec env -i LFS_CLEAN_ENV=1 HOME="$HOME" USER="$(id -un)" TERM="${TERM:-xterm}" \
        PATH=/usr/bin:/bin /bin/bash "$0" "$@"
fi

umask 022
export LC_ALL=POSIX
export PATH="$LFS/tools/bin:/usr/bin:/bin"
export MAKEFLAGS="-j$(nproc)"
export LFS LFS_TGT

SRC="$LFS/sources"
LOGS="$SRC/logs"
STAMPS="$SRC/.stamps"
GNUPGHOME_TMP="$SRC/.gnupg"

die()  { echo; echo "!! $*" >&2; exit 1; }
info() { echo "==> $*"; }

run_step() {
    local name=$1 fn=$2 rc
    if [ -f "$STAMPS/$name" ]; then
        info "$name: already done, skipping"
        return
    fi
    info "$name: started $(date +%H:%M)  (log: $LOGS/$name.log)"
    set +e
    ( set -euo pipefail; "$fn" ) >"$LOGS/$name.log" 2>&1
    rc=$?
    set -e
    if [ "$rc" -ne 0 ]; then
        tail -n 40 "$LOGS/$name.log"
        die "$name failed. Full log: $LOGS/$name.log"
    fi
    touch "$STAMPS/$name"
    info "$name: done $(date +%H:%M)"
}

preflight() {
    [ "$(id -u)" -ne 0 ] || die "run this as your normal user, not root"
    mountpoint -q "$LFS" || die "$LFS is not mounted"
    [ -O "$SRC" ] || die "$SRC is not owned by you. Has the system already been handed to root (enter-chroot.sh)?"
    [ -f "$SRC/VERSIONS" ] || die "run build-toolchain.sh first"
    [ -f "$STAMPS/08-test-cxx" ] || die "the toolchain did not finish; run build-toolchain.sh again"
    command -v "$LFS_TGT-gcc" >/dev/null || die "cross compiler not found in $LFS/tools/bin"
    local c missing=""
    for c in gcc make m4 wget gpg gpgv bzip2 xz tar sha256sum; do
        command -v "$c" >/dev/null || missing="$missing $c"
    done
    [ -z "$missing" ] || die "missing host tools:$missing"
}

fetch() {
    local f
    f="$SRC/$(basename "$1")"
    if [ -s "$f" ]; then return; fi
    wget -q --show-progress -O "$f.part" "$1" || { rm -f "$f.part"; die "download failed: $1"; }
    mv "$f.part" "$f"
}

# latest_gnu <name> <ext regex>  -> newest version number on ftp.gnu.org
latest_gnu() {
    wget -qO- "https://ftp.gnu.org/gnu/$1/" \
        | grep -oE "$1-[0-9]+\.[0-9]+(\.[0-9]+)*\.$2" \
        | sed -e "s/^$1-//" -e "s/\.$2\$//" | sort -uV | tail -n1 || true
}

pin() {   # pin VAR name ext  -> detect once, append to VERSIONS
    local var=$1 name=$2 ext=$3 v
    if [ -n "${!var:-}" ]; then
        grep -q "^$var=" "$SRC/VERSIONS" || echo "$var=${!var}" >> "$SRC/VERSIONS"
        return
    fi
    v=$(latest_gnu "$name" "$ext")
    [ -n "$v" ] || die "could not detect the latest $name version"
    printf -v "$var" '%s' "$v"
    echo "$var=$v" >> "$SRC/VERSIONS"
}

download_and_verify() {
    cd "$SRC"
    pin M4_VER   m4   'tar\.xz'
    pin MAKE_VER make 'tar\.gz'
    pin GAWK_VER gawk 'tar\.xz'
    pin BASH_VER bash 'tar\.gz'
    grep -q '^BUSYBOX_VER=' VERSIONS || echo "BUSYBOX_VER=$BUSYBOX_VER" >> VERSIONS

    info "versions: m4 $M4_VER, make $MAKE_VER, gawk $GAWK_VER, bash $BASH_VER, busybox $BUSYBOX_VER"

    local p
    for p in "m4/m4-$M4_VER.tar.xz" "make/make-$MAKE_VER.tar.gz" \
             "gawk/gawk-$GAWK_VER.tar.xz" "bash/bash-$BASH_VER.tar.gz"; do
        fetch "https://ftp.gnu.org/gnu/$p"
        fetch "https://ftp.gnu.org/gnu/$p.sig"
        gpgv --homedir "$GNUPGHOME_TMP" --keyring "$SRC/gnu-keyring.gpg" \
            "$(basename "$p").sig" "$(basename "$p")" \
            || die "SIGNATURE CHECK FAILED: $(basename "$p")"
    done

    fetch "https://busybox.net/downloads/busybox-$BUSYBOX_VER.tar.bz2"
    fetch "https://busybox.net/downloads/busybox-$BUSYBOX_VER.tar.bz2.sig"
    info "verifying BusyBox (its signing key is fetched from keyserver.ubuntu.com)"
    gpg --homedir "$GNUPGHOME_TMP" --keyserver hkps://keyserver.ubuntu.com \
        --auto-key-retrieve --verify \
        "busybox-$BUSYBOX_VER.tar.bz2.sig" "busybox-$BUSYBOX_VER.tar.bz2" \
        || die "SIGNATURE CHECK FAILED (or keyserver unreachable): busybox"
    info "all signatures OK"

    find . -maxdepth 1 -type f -name '*.tar.*' ! -name '*.sig' ! -name '*.asc' \
        | sort | xargs sha256sum > SHA256SUMS
}

unpack() {   # unpack <tarball> <dir>  -> fresh source dir, cd into it
    cd "$SRC"; rm -rf "$2"; tar xf "$1"; cd "$2"
}

# ---------------- build steps ----------------

s_m4() {
    unpack "m4-$M4_VER.tar.xz" "m4-$M4_VER"
    ./configure --prefix=/usr --host="$LFS_TGT" --build="$BUILD"
    make
    make DESTDIR="$LFS" install
    cd "$SRC"; rm -rf "m4-$M4_VER"
}

s_make() {
    unpack "make-$MAKE_VER.tar.gz" "make-$MAKE_VER"
    # make 4.4.1 has pre-C23 code (extern char *getenv ();). GCC 15+ defaults
    # to C23, where () means "no arguments", so build it as C17.
    ./configure --prefix=/usr --host="$LFS_TGT" --build="$BUILD" --without-guile \
        CFLAGS="-O2 -std=gnu17"
    make
    make DESTDIR="$LFS" install
    cd "$SRC"; rm -rf "make-$MAKE_VER"
}

s_gawk() {
    unpack "gawk-$GAWK_VER.tar.xz" "gawk-$GAWK_VER"
    sed -i 's/extras//' Makefile.in
    ./configure --prefix=/usr --host="$LFS_TGT" --build="$BUILD"
    make
    make DESTDIR="$LFS" install
    cd "$SRC"; rm -rf "gawk-$GAWK_VER"
}

s_busybox() {
    unpack "busybox-$BUSYBOX_VER.tar.bz2" "busybox-$BUSYBOX_VER"
    make defconfig
    # tc: broken with current kernel headers. SHA hw-accel: breaks with PIE.
    # linuxrc: not needed, and would write outside our directories.
    sed -i \
        -e 's/^CONFIG_TC=y/# CONFIG_TC is not set/' \
        -e 's/^CONFIG_SHA1_HWACCEL=y/# CONFIG_SHA1_HWACCEL is not set/' \
        -e 's/^CONFIG_SHA256_HWACCEL=y/# CONFIG_SHA256_HWACCEL is not set/' \
        -e 's/^CONFIG_LINUXRC=y/# CONFIG_LINUXRC is not set/' \
        .config
    make CROSS_COMPILE="$LFS_TGT-"
    make CROSS_COMPILE="$LFS_TGT-" CONFIG_PREFIX="$LFS" install
    cd "$SRC"; rm -rf "busybox-$BUSYBOX_VER"
}

s_bash() {
    unpack "bash-$BASH_VER.tar.gz" "bash-$BASH_VER"
    ./configure --prefix=/usr --host="$LFS_TGT" --build="$BUILD" --without-bash-malloc
    make
    make DESTDIR="$LFS" install
    ln -sf bash "$LFS/usr/bin/sh"     # bash as /bin/sh while building; revisit later
    cd "$SRC"; rm -rf "bash-$BASH_VER"
}

s_binutils2() {
    unpack "binutils-$BINUTILS_VER.tar.xz" "binutils-$BINUTILS_VER"
    mkdir build; cd build
    ../configure --prefix=/usr --build="$BUILD" --host="$LFS_TGT" \
        --disable-nls --disable-shared --enable-gprofng=no --disable-werror \
        --enable-64-bit-bfd --enable-new-dtags --enable-default-hash-style=gnu
    make
    make DESTDIR="$LFS" install
    cd "$SRC"; rm -rf "binutils-$BINUTILS_VER"
}

s_gcc_native() {
    [ -d "$SRC/gcc-$GCC_VER" ] || { echo "gcc source tree missing"; exit 1; }
    cd "$SRC/gcc-$GCC_VER"
    sed '/thread_header =/s/@.*@/gthr-posix.h/' \
        -i libgcc/Makefile.in libstdc++-v3/include/Makefile.in
    rm -rf build3; mkdir build3; cd build3
    ../configure --build="$BUILD" --host="$LFS_TGT" --target="$LFS_TGT" \
        LDFLAGS_FOR_TARGET="-L$PWD/$LFS_TGT/libgcc" \
        --prefix=/usr --with-build-sysroot="$LFS" \
        --enable-default-pie --enable-default-ssp \
        --disable-nls --disable-multilib --disable-libatomic --disable-libgomp \
        --disable-libquadmath --disable-libsanitizer --disable-libssp --disable-libvtv \
        --disable-symvers --disable-libstdcxx-pch \
        --enable-languages=c,c++
    make
    make DESTDIR="$LFS" install
    ln -sf gcc "$LFS/usr/bin/cc"
}

# ---------------- main ----------------

preflight
mkdir -p "$LOGS" "$STAMPS"
. "$SRC/VERSIONS"
BUILD=$(gcc -dumpmachine)       # the Void host's own triplet
download_and_verify

run_step 10-m4          s_m4
run_step 11-make        s_make
run_step 12-gawk        s_gawk
run_step 13-busybox     s_busybox
run_step 14-bash        s_bash
run_step 15-binutils2   s_binutils2
run_step 16-gcc-native  s_gcc_native

echo
info "Temporary system finished."
info "Next: sudo ~/cig/scripts/enter-chroot.sh"
