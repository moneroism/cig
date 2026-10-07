#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 moneroism
# build-temp.sh - phase 2: temporary system for the hardened distro
#
# Cross-compiles into /mnt/cig, using the toolchain from build-toolchain.sh:
#   m4, make, gawk, BusyBox, bash, binutils (native), gcc (native)
# Afterwards /mnt/cig can be entered with enter-chroot.sh and the distro
# builds itself from then on.
#
# Run as your NORMAL user, after build-toolchain.sh has finished.
# Safe to re-run: finished steps are skipped, a failed step restarts.

set -euo pipefail

# ---------------- settings ----------------
SYS=/mnt/cig
TGT=x86_64-cig-linux-musl
REPO="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
# versions and signing keys come from the recipes (packages/<name>/recipe, keys/)
rvar() { CIG_REPO=$REPO bash -c '. "$0/packages/$1/recipe" >/dev/null 2>&1; eval "echo \"\$$2\""' "$REPO" "$1" "$2"; }
M4_VER=$(rvar m4 version)
MAKE_VER=$(rvar make version)
GAWK_VER=$(rvar gawk version)    # 5.4.x breaks GCC 16's option generator (opt-gather.awk)
BASH_VER=$(rvar bash version)
BUSYBOX_VER=1.36.1     # the temporary system's BusyBox (defconfig, tested); the final one is the recipe's
# ------------------------------------------

if [ -z "${CIG_CLEAN_ENV:-}" ]; then
    exec env -i CIG_CLEAN_ENV=1 HOME="$HOME" USER="$(id -un)" TERM="${TERM:-xterm}" \
        PATH=/usr/bin:/bin /bin/bash "$0" "$@"
fi

umask 022
export LC_ALL=POSIX
export PATH="$SYS/tools/bin:/usr/bin:/bin"
export MAKEFLAGS="-j$(nproc)"
export SYS TGT

SRC="$SYS/sources"
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
    mountpoint -q "$SYS" || die "$SYS is not mounted"
    [ -O "$SRC" ] || die "$SRC is not owned by you. Has the system already been handed to root (enter-chroot.sh)?"
    [ -f "$SRC/VERSIONS" ] || die "run build-toolchain.sh first"
    [ -f "$STAMPS/08-test-cxx" ] || die "the toolchain did not finish; run build-toolchain.sh again"
    command -v "$TGT-gcc" >/dev/null || die "cross compiler not found in $SYS/tools/bin"
    local c missing=""
    [ -n "$M4_VER" ] && [ -n "$MAKE_VER" ] && [ -n "$GAWK_VER" ] && [ -n "$BASH_VER" ] \
        || die "could not read the versions from $REPO/packages"
    for c in gcc make m4 wget gpgv bzip2 xz tar sha256sum; do
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

# keyring <pkg>: the recipe's signing keys (keys= -> keys/<fingerprint>.gpg), and no others
keyring() {
    local k out="$SRC/keys-$1.gpg"
    : > "$out"
    for k in $(rvar "$1" keys); do
        [ -s "$REPO/keys/$k.gpg" ] || die "$1: key $k is not in $REPO/keys"
        cat "$REPO/keys/$k.gpg" >> "$out"
    done
    [ -s "$out" ] || die "$1: the recipe lists no keys="
    echo "$out"
}

download_and_verify() {
    cd "$SRC"
    local v
    for v in M4_VER MAKE_VER GAWK_VER BASH_VER BUSYBOX_VER; do
        grep -q "^$v=" VERSIONS || echo "$v=${!v}" >> VERSIONS
    done
    info "versions: m4 $M4_VER, make $MAKE_VER, gawk $GAWK_VER, bash $BASH_VER, busybox $BUSYBOX_VER"
    mkdir -p "$GNUPGHOME_TMP"; chmod 700 "$GNUPGHOME_TMP"

    local p n
    for p in "m4/m4-$M4_VER.tar.xz" "make/make-$MAKE_VER.tar.gz" \
             "gawk/gawk-$GAWK_VER.tar.xz" "bash/bash-$BASH_VER.tar.gz"; do
        fetch "https://ftp.gnu.org/gnu/$p"
        fetch "https://ftp.gnu.org/gnu/$p.sig"
        n=${p%%/*}
        gpgv --homedir "$GNUPGHOME_TMP" --keyring "$(keyring "$n")" \
            "$(basename "$p").sig" "$(basename "$p")" \
            || die "SIGNATURE CHECK FAILED: $(basename "$p")"
    done

    fetch "https://busybox.net/downloads/busybox-$BUSYBOX_VER.tar.bz2"
    fetch "https://busybox.net/downloads/busybox-$BUSYBOX_VER.tar.bz2.sig"
    gpgv --homedir "$GNUPGHOME_TMP" --keyring "$(keyring busybox)" \
        "busybox-$BUSYBOX_VER.tar.bz2.sig" "busybox-$BUSYBOX_VER.tar.bz2" \
        || die "SIGNATURE CHECK FAILED: busybox"
    info "all signatures OK"

    find . -maxdepth 1 -type f -name '*.tar.*' ! -name '*.sig' ! -name '*.asc' ! -name '*.sign' \
        | sort | xargs sha256sum > SHA256SUMS
}

unpack() {   # unpack <tarball> <dir>  -> fresh source dir, cd into it
    cd "$SRC"; rm -rf "$2"; tar xf "$1"; cd "$2"
}

# ---------------- build steps ----------------

s_m4() {
    unpack "m4-$M4_VER.tar.xz" "m4-$M4_VER"
    ./configure --prefix=/usr --host="$TGT" --build="$BUILD"
    make
    make DESTDIR="$SYS" install
    cd "$SRC"; rm -rf "m4-$M4_VER"
}

s_make() {
    unpack "make-$MAKE_VER.tar.gz" "make-$MAKE_VER"
    # make 4.4.1 has pre-C23 code (extern char *getenv ();). GCC 15+ defaults
    # to C23, where () means "no arguments", so build it as C17.
    ./configure --prefix=/usr --host="$TGT" --build="$BUILD" --without-guile \
        CFLAGS="-O2 -std=gnu17"
    make
    make DESTDIR="$SYS" install
    cd "$SRC"; rm -rf "make-$MAKE_VER"
}

s_gawk() {
    unpack "gawk-$GAWK_VER.tar.xz" "gawk-$GAWK_VER"
    sed -i 's/extras//' Makefile.in
    ./configure --prefix=/usr --host="$TGT" --build="$BUILD"
    make
    make DESTDIR="$SYS" install
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
    make CROSS_COMPILE="$TGT-"
    make CROSS_COMPILE="$TGT-" CONFIG_PREFIX="$SYS" install
    cd "$SRC"; rm -rf "busybox-$BUSYBOX_VER"
}

s_bash() {
    unpack "bash-$BASH_VER.tar.gz" "bash-$BASH_VER"
    ./configure --prefix=/usr --host="$TGT" --build="$BUILD" --without-bash-malloc
    make
    make DESTDIR="$SYS" install
    ln -sf bash "$SYS/usr/bin/sh"     # bash as /bin/sh while building; revisit later
    cd "$SRC"; rm -rf "bash-$BASH_VER"
}

s_binutils2() {
    unpack "binutils-$BINUTILS_VER.tar.xz" "binutils-$BINUTILS_VER"
    mkdir build; cd build
    ../configure --prefix=/usr --build="$BUILD" --host="$TGT" \
        --disable-nls --disable-shared --enable-gprofng=no --disable-werror \
        --enable-64-bit-bfd --enable-new-dtags --enable-default-hash-style=gnu
    make
    make DESTDIR="$SYS" install
    cd "$SRC"; rm -rf "binutils-$BINUTILS_VER"
}

s_gcc_native() {
    [ -d "$SRC/gcc-$GCC_VER" ] || { echo "gcc source tree missing"; exit 1; }
    cd "$SRC/gcc-$GCC_VER"
    sed '/thread_header =/s/@.*@/gthr-posix.h/' \
        -i libgcc/Makefile.in libstdc++-v3/include/Makefile.in
    rm -rf build3; mkdir build3; cd build3
    ../configure --build="$BUILD" --host="$TGT" --target="$TGT" \
        LDFLAGS_FOR_TARGET="-L$PWD/$TGT/libgcc" \
        --prefix=/usr --with-build-sysroot="$SYS" \
        --enable-default-pie --enable-default-ssp \
        --disable-nls --disable-multilib --disable-libatomic --disable-libgomp \
        --disable-libquadmath --disable-libsanitizer --disable-libssp --disable-libvtv \
        --disable-symvers --disable-libstdcxx-pch \
        --enable-languages=c,c++
    make
    make DESTDIR="$SYS" install
    ln -sf gcc "$SYS/usr/bin/cc"
}

# ---------------- main ----------------

preflight
mkdir -p "$LOGS" "$STAMPS"
. "$SRC/VERSIONS"   # binutils and gcc from build-toolchain.sh; a re-run keeps what it recorded
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
info "Next: sudo $REPO/scripts/enter-chroot.sh"
