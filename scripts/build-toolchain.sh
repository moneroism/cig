#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 moneroism
# build-toolchain.sh - musl cross-toolchain for the hardened distro
#
# Builds: binutils (pass 1) -> kernel headers -> gcc (pass 1, C only)
#         -> musl -> gcc (pass 2, C + C++)
# Everything goes into /mnt/cig. Nothing on Void is modified.
#
# Run as your NORMAL user (not root, not sudo). It asks for sudo once,
# only to create the directory layout in /mnt/cig.
# Safe to re-run: finished steps are skipped, a failed step restarts.

set -euo pipefail

# ---------------- settings ----------------
SYS=/mnt/cig
TGT=x86_64-cig-linux-musl
REPO="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
# versions and signing keys come from the recipes (packages/<name>/recipe, keys/), the same
# record cigbuild builds the final system from
rvar() { CIG_REPO=$REPO bash -c '. "$0/packages/$1/recipe" >/dev/null 2>&1; eval "echo \"\$$2\""' "$REPO" "$1" "$2"; }
BINUTILS_VER=$(rvar binutils version)
GCC_VER=$(rvar gcc version)
MUSL_VER=$(rvar musl version)
KVER=$(rvar linux _kver)   # kernel headers: the signed kernel.org release the linux recipe uses
# ------------------------------------------

# Restart with a clean environment so nothing from Void leaks into the build
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

die()  { echo; echo "!! $*" >&2; exit 1; }
info() { echo "==> $*"; }

# run_step <name> <function>: logs to $LOGS/<name>.log, skips if already done
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
    mountpoint -q "$SYS" || die "$SYS is not mounted. Attach the image (losetup) and mount it first."
    [ -n "$BINUTILS_VER" ] && [ -n "$GCC_VER" ] && [ -n "$MUSL_VER" ] && [ -n "$KVER" ] \
        || die "could not read the versions from $REPO/packages"
    local c missing=""
    for c in gcc g++ make bison gawk m4 makeinfo patch perl python3 tar xz \
             wget gpgv readelf sha256sum rsync sudo; do
        command -v "$c" >/dev/null || missing="$missing $c"
    done
    [ -z "$missing" ] || die "missing host tools:$missing"
}

setup_layout() {
    if [ -d "$SRC" ] && [ -O "$SRC" ]; then return; fi
    info "creating directory layout in $SYS (sudo password needed once)"
    sudo mkdir -p "$SYS"/{etc,var,usr/{bin,lib,sbin},tools,sources}
    local i
    for i in bin lib sbin; do
        [ -e "$SYS/$i" ] || sudo ln -s "usr/$i" "$SYS/$i"
    done
    sudo chown "$(id -u):$(id -g)" \
        "$SYS"/{usr,usr/bin,usr/lib,usr/sbin,var,etc,tools,sources}
}

fetch() {   # fetch <url>  ->  $SRC/<file name>
    local f
    f="$SRC/$(basename "$1")"
    if [ -s "$f" ]; then return; fi
    wget -q --show-progress -O "$f.part" "$1" || { rm -f "$f.part"; die "download failed: $1"; }
    mv "$f.part" "$f"
}

# keyring <pkg>: $KEYRING = a file with the recipe's signing keys (keys= -> keys/<fingerprint>.gpg),
# and no others. Called in the main shell, not as $(keyring): a die there would only end the subshell
keyring() {
    local k out="$SRC/keys-$1.gpg"
    : > "$out"
    for k in $(rvar "$1" keys); do
        [ -s "$REPO/keys/$k.gpg" ] || die "$1: key $k is not in $REPO/keys"
        cat "$REPO/keys/$k.gpg" >> "$out"
    done
    [ -s "$out" ] || die "$1: the recipe lists no keys="
    KEYRING=$out
}

download_and_verify() {
    cd "$SRC"
    info "versions: binutils $BINUTILS_VER, gcc $GCC_VER, musl $MUSL_VER, kernel headers $KVER"

    fetch "https://ftp.gnu.org/gnu/binutils/binutils-$BINUTILS_VER.tar.xz"
    fetch "https://ftp.gnu.org/gnu/binutils/binutils-$BINUTILS_VER.tar.xz.sig"
    fetch "https://ftp.gnu.org/gnu/gcc/gcc-$GCC_VER/gcc-$GCC_VER.tar.xz"
    fetch "https://ftp.gnu.org/gnu/gcc/gcc-$GCC_VER/gcc-$GCC_VER.tar.xz.sig"
    fetch "https://musl.libc.org/releases/musl-$MUSL_VER.tar.gz"
    fetch "https://musl.libc.org/releases/musl-$MUSL_VER.tar.gz.asc"
    fetch "https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-$KVER.tar.xz"
    fetch "https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-$KVER.tar.sign"

    local gh="$SRC/.gnupg"
    mkdir -p "$gh"; chmod 700 "$gh"

    info "checking signatures (keys from the recipes)"
    keyring binutils
    gpgv --homedir "$gh" --keyring "$KEYRING" \
        "binutils-$BINUTILS_VER.tar.xz.sig" "binutils-$BINUTILS_VER.tar.xz" \
        || die "SIGNATURE CHECK FAILED: binutils"
    keyring gcc
    gpgv --homedir "$gh" --keyring "$KEYRING" \
        "gcc-$GCC_VER.tar.xz.sig" "gcc-$GCC_VER.tar.xz" \
        || die "SIGNATURE CHECK FAILED: gcc"
    keyring musl
    gpgv --homedir "$gh" --keyring "$KEYRING" \
        "musl-$MUSL_VER.tar.gz.asc" "musl-$MUSL_VER.tar.gz" \
        || die "SIGNATURE CHECK FAILED: musl"
    # kernel.org signs the uncompressed tarball
    keyring linux
    xz -dc "linux-$KVER.tar.xz" | gpgv --homedir "$gh" --keyring "$KEYRING" \
        "linux-$KVER.tar.sign" - || die "SIGNATURE CHECK FAILED: linux"
    info "all signatures OK"

    # Pin versions and record checksums: the start of the distro's build record
    cat > "$SRC/VERSIONS" <<EOF
BINUTILS_VER=$BINUTILS_VER
GCC_VER=$GCC_VER
MUSL_VER=$MUSL_VER
KVER=$KVER
EOF
    sha256sum "binutils-$BINUTILS_VER.tar.xz" "gcc-$GCC_VER.tar.xz" \
        "musl-$MUSL_VER.tar.gz" "linux-$KVER.tar.xz" > "$SRC/SHA256SUMS"
}

# ---------------- build steps ----------------

s_binutils1() {
    cd "$SRC"; rm -rf "binutils-$BINUTILS_VER"
    tar xf "binutils-$BINUTILS_VER.tar.xz"
    cd "binutils-$BINUTILS_VER"; mkdir build; cd build
    ../configure --prefix="$SYS/tools" --with-sysroot="$SYS" --target="$TGT" \
        --disable-nls --enable-gprofng=no --disable-werror \
        --enable-new-dtags --enable-default-hash-style=gnu
    make
    make install
    cd "$SRC"; rm -rf "binutils-$BINUTILS_VER"
}

s_kernel_headers() {
    cd "$SRC"; rm -rf "linux-$KVER"
    tar xf "linux-$KVER.tar.xz"
    make -C "linux-$KVER" headers_install ARCH=x86_64 INSTALL_HDR_PATH="$SYS/usr"
    rm -rf "linux-$KVER"
}

s_gcc_prep() {
    cd "$SRC"; rm -rf "gcc-$GCC_VER"
    tar xf "gcc-$GCC_VER.tar.xz"
    cd "gcc-$GCC_VER"
    ./contrib/download_prerequisites     # gmp/mpfr/mpc, checked against sha512 in gcc's source
    sed -e '/m64=/s/lib64/lib/' -i.orig gcc/config/i386/t-linux64
}

s_gcc1() {
    cd "$SRC/gcc-$GCC_VER"; rm -rf build1; mkdir build1; cd build1
    ../configure --target="$TGT" --prefix="$SYS/tools" --with-sysroot="$SYS" \
        --with-newlib --without-headers \
        --enable-default-pie --enable-default-ssp \
        --disable-nls --disable-shared --disable-multilib --disable-threads \
        --disable-libatomic --disable-libgomp --disable-libquadmath --disable-libssp \
        --disable-libvtv --disable-libstdcxx --disable-libsanitizer \
        --enable-languages=c
    make
    make install
    cd ..
    cat gcc/limitx.h gcc/glimits.h gcc/limity.h \
        > "$(dirname "$("$TGT-gcc" -print-libgcc-file-name)")/include/limits.h"
}

s_musl() {
    cd "$SRC"; rm -rf "musl-$MUSL_VER"
    tar xf "musl-$MUSL_VER.tar.gz"
    cd "musl-$MUSL_VER"
    ./configure CROSS_COMPILE="$TGT-" --prefix=/usr --target="$TGT"
    make
    make DESTDIR="$SYS" install
    cd "$SRC"; rm -rf "musl-$MUSL_VER"
}

s_test_c() {
    cd "$SRC"
    echo 'int main(void) { return 0; }' > t.c
    "$TGT-gcc" t.c -o t
    readelf -l t | grep 'interpreter'
    readelf -l t | grep -q '/lib/ld-musl-x86_64.so.1' || { echo "wrong dynamic linker"; exit 1; }
    rm -f t t.c
}

s_gcc2() {
    cd "$SRC/gcc-$GCC_VER"; rm -rf build2; mkdir build2; cd build2
    ../configure --target="$TGT" --prefix="$SYS/tools" --with-sysroot="$SYS" \
        --enable-languages=c,c++ \
        --enable-default-pie --enable-default-ssp \
        --enable-shared --enable-threads=posix --enable-tls --enable-__cxa_atexit \
        --disable-nls --disable-multilib --disable-libsanitizer --disable-libssp \
        --disable-libvtv --disable-symvers --disable-libstdcxx-pch --disable-werror
    make
    make install
}

s_test_cxx() {
    cd "$SRC"
    cat > t.cpp <<'EOF'
#include <iostream>
int main() { std::cout << "ok\n"; }
EOF
    "$TGT-g++" t.cpp -o t
    readelf -l t | grep -q '/lib/ld-musl-x86_64.so.1' || { echo "wrong dynamic linker"; exit 1; }
    rm -f t t.cpp
}

# ---------------- main ----------------

preflight
setup_layout
mkdir -p "$LOGS" "$STAMPS"
if [ -f "$SRC/VERSIONS" ]; then . "$SRC/VERSIONS"; fi
download_and_verify

run_step 01-binutils-pass1  s_binutils1
run_step 02-kernel-headers  s_kernel_headers
run_step 03-gcc-prep        s_gcc_prep
run_step 04-gcc-pass1       s_gcc1
run_step 05-musl            s_musl
run_step 06-test-c          s_test_c
run_step 07-gcc-pass2       s_gcc2
run_step 08-test-cxx        s_test_cxx

echo
info "Toolchain finished."
info "Compiler: $SYS/tools/bin/$TGT-gcc (C) and -g++ (C++)"
info "Versions: $SRC/VERSIONS   Checksums: $SRC/SHA256SUMS"
info "Hardening on by default: PIE + stack protector for everything it builds."
