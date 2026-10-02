#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 moneroism
# build-essentials.sh - phase 4, run INSIDE the chroot:
#     bash /sources/build-essentials.sh
#
# zlib, e2fsprogs, perl, OpenSSL 3.5 LTS, CA bundle, curl, git,
# libnl, wpa_supplicant, plus DHCP + WiFi services for runit.
#
# Every package is installed into a staging folder first, then copied
# into the system. Before copying, any BusyBox link with the same name is
# removed, so an install can never write *through* a link into BusyBox.

set -euo pipefail

export PATH=/usr/bin:/usr/sbin
export LC_ALL=POSIX
export MAKEFLAGS="-j$(nproc)"
umask 022

SRC=/sources
LOGS="$SRC/logs"
STAMPS="$SRC/.stamps"
S=/tmp/stage          # DESTDIR for the package being built

die()  { echo; echo "!! $*" >&2; exit 1; }
info() { echo "==> $*"; }

run_step() {
    local name=$1 fn=$2 rc
    if [ -f "$STAMPS/$name" ]; then info "$name: already done, skipping"; return; fi
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

unpack() { cd "$SRC"; rm -rf "$2"; tar xf "$1"; cd "$2"; }

# copy a DESTDIR tree into the live system, safely
stage_install() {
    local d f t
    # merged /usr: anything staged in /bin, /sbin, /lib, /lib64 goes under /usr
    for d in bin sbin lib lib64; do
        if [ -d "$S/$d" ] && [ ! -L "$S/$d" ]; then
            t=$d; [ "$d" = lib64 ] && t=lib
            mkdir -p "$S/usr/$t"
            cp -a "$S/$d/." "$S/usr/$t/"
            rm -rf "$S/$d"
        fi
    done
    # remove BusyBox links that this package replaces
    ( cd "$S" && find . ! -type d ) | while read -r f; do
        t="/${f#./}"
        if [ -L "$t" ]; then
            case "$(readlink "$t")" in *busybox) rm -f "$t" ;; esac
        fi
    done
    cp -a "$S/." /
    rm -rf "$S"
}

# ---------------- preflight ----------------
[ "$(id -u)" -eq 0 ] || die "run as root inside the chroot"
[ -f /etc/.handed-to-root ] || die "this must run inside the chroot"
. "$SRC/VERSIONS"
[ -n "${OPENSSL_VER:-}" ] || die "run prepare-essentials.sh on Void first"
mkdir -p "$LOGS" "$STAMPS"

# ---------------- packages ----------------

s_zlib() {
    unpack "zlib-$ZLIB_VER.tar.gz" "zlib-$ZLIB_VER"
    ./configure --prefix=/usr
    make
    rm -rf "$S"; make DESTDIR="$S" install
    rm -f "$S/usr/lib/libz.a"
    stage_install
    cd "$SRC"; rm -rf "zlib-$ZLIB_VER"
}

s_e2fsprogs() {
    unpack "e2fsprogs-$E2FS_VER.tar.xz" "e2fsprogs-$E2FS_VER"
    mkdir build; cd build
    ../configure --prefix=/usr --sysconfdir=/etc \
        --enable-elf-shlibs --disable-uuidd --disable-fsck --disable-nls
    make MAKEINFO=true
    rm -rf "$S"; make MAKEINFO=true DESTDIR="$S" install
    rm -f "$S"/usr/lib/*.a
    stage_install
    cd "$SRC"; rm -rf "e2fsprogs-$E2FS_VER"
}

s_perl() {
    unpack "perl-$PERL_VER.tar.xz" "perl-$PERL_VER"
    sh Configure -des -Dprefix=/usr -Dvendorprefix=/usr \
        -Duseshrplib -Dusethreads -Dman1dir=none -Dman3dir=none
    make
    rm -rf "$S"; make DESTDIR="$S" install
    stage_install
    cd "$SRC"; rm -rf "perl-$PERL_VER"
}

s_openssl() {
    unpack "openssl-$OPENSSL_VER.tar.gz" "openssl-$OPENSSL_VER"
    ./Configure linux-x86_64 --prefix=/usr --openssldir=/etc/ssl --libdir=lib \
        shared zlib-dynamic no-ssl3 no-weak-ssl-ciphers \
        -Wl,-z,relro,-z,now
    make
    rm -rf "$S"; make DESTDIR="$S" install_sw install_ssldirs
    rm -f "$S"/usr/lib/libcrypto.a "$S"/usr/lib/libssl.a
    stage_install
    cd "$SRC"; rm -rf "openssl-$OPENSSL_VER"
}

s_cacerts() {
    install -D -m 644 "$SRC/cacert.pem" /etc/ssl/cert.pem
    mkdir -p /etc/ssl/certs
    ln -sf ../cert.pem /etc/ssl/certs/ca-certificates.crt
}

s_curl() {
    unpack "curl-$CURL_VER.tar.xz" "curl-$CURL_VER"
    # only HTTP(S) + FILE: everything else is attack surface you don't use
    ./configure --prefix=/usr --disable-static \
        --with-openssl --with-ca-bundle=/etc/ssl/cert.pem \
        --without-libpsl --without-libidn2 --without-brotli --without-zstd \
        --disable-ldap --disable-ldaps --disable-rtsp --disable-dict --disable-telnet \
        --disable-tftp --disable-pop3 --disable-imap --disable-smtp --disable-gopher \
        --disable-mqtt --disable-smb --disable-manual
    make
    rm -rf "$S"; make DESTDIR="$S" install
    find "$S" -name '*.la' -delete
    stage_install
    cd "$SRC"; rm -rf "curl-$CURL_VER"
}

s_git() {
    unpack "git-$GIT_VER.tar.xz" "git-$GIT_VER"
    # musl's regex lacks REG_STARTEND -> git's own regex
    # NO_RUST: git 2.54+ builds Rust parts by default; we have no Rust toolchain
    local GITOPTS="prefix=/usr NO_PERL=1 NO_PYTHON=1 NO_TCLTK=1 NO_GETTEXT=1 NO_EXPAT=1
                   NO_REGEX=NeedsStartEnd NO_RUST=1 INSTALL_SYMLINKS=1"
    make $GITOPTS
    rm -rf "$S"; make $GITOPTS DESTDIR="$S" install
    stage_install
    cd "$SRC"; rm -rf "git-$GIT_VER"
}

s_bison() {
    unpack "bison-$BISON_VER.tar.xz" "bison-$BISON_VER"
    ./configure --prefix=/usr --disable-nls
    make MAKEINFO=true
    rm -rf "$S"; make MAKEINFO=true DESTDIR="$S" install
    stage_install
    cd "$SRC"; rm -rf "bison-$BISON_VER"
}

s_flex() {
    unpack "flex-$FLEX_VER.tar.gz" "flex-$FLEX_VER"
    # flex 2.6.4 predates C23 (GCC 15+ default), so build it as C17
    ./configure --prefix=/usr --disable-static --disable-nls CFLAGS="-O2 -std=gnu17"
    make MAKEINFO=true HELP2MAN=true
    rm -rf "$S"; make MAKEINFO=true HELP2MAN=true DESTDIR="$S" install
    ln -sf flex "$S/usr/bin/lex"
    find "$S" -name '*.la' -delete
    stage_install
    cd "$SRC"; rm -rf "flex-$FLEX_VER"
}

s_libnl() {
    unpack "libnl-$LIBNL_VER.tar.gz" "libnl-$LIBNL_VER"
    ./configure --prefix=/usr --sysconfdir=/etc --disable-static --disable-cli
    make
    rm -rf "$S"; make DESTDIR="$S" install
    find "$S" -name '*.la' -delete
    stage_install
    cd "$SRC"; rm -rf "libnl-$LIBNL_VER"
}

s_wpa() {
    unpack "wpa_supplicant-$WPA_VER.tar.gz" "wpa_supplicant-$WPA_VER"
    cd wpa_supplicant
    # minimal: WPA2/WPA3-Personal over nl80211. No WPS, no D-Bus, no EAP.
    cat > .config <<'EOF'
CONFIG_DRIVER_NL80211=y
CONFIG_LIBNL32=y
LIBNL_INC=/usr/include/libnl3
CONFIG_TLS=openssl
CONFIG_CTRL_IFACE=y
CONFIG_BACKEND=file
CONFIG_SAE=y
CONFIG_IEEE80211W=y
CONFIG_IEEE80211N=y
CONFIG_IEEE80211AC=y
EOF
    make BINDIR=/usr/sbin LIBDIR=/usr/lib
    install -D -m 755 wpa_supplicant "$S/usr/sbin/wpa_supplicant"
    install -D -m 755 wpa_cli        "$S/usr/sbin/wpa_cli"
    install -D -m 755 wpa_passphrase "$S/usr/sbin/wpa_passphrase"
    stage_install
    cd "$SRC"; rm -rf "wpa_supplicant-$WPA_VER"
}

# ---------------- networking setup ----------------

s_network() {
    # DHCP client script, from BusyBox's own examples
    mkdir -p /usr/share/udhcpc
    tar -xjf "$SRC/busybox-$BUSYBOX_VER.tar.bz2" -O \
        "busybox-$BUSYBOX_VER/examples/udhcp/simple.script" > /usr/share/udhcpc/default.script
    chmod 755 /usr/share/udhcpc/default.script

    # one DHCP service per interface; eth0 enabled (VM), wlan0 ready for later
    local i
    for i in eth0 wlan0; do
        mkdir -p "/etc/sv/udhcpc-$i"
        cat > "/etc/sv/udhcpc-$i/run" <<EOF
#!/bin/sh
ip link set $i up 2>/dev/null
exec udhcpc -f -i $i
EOF
        chmod 755 "/etc/sv/udhcpc-$i/run"
    done
    ln -sfn /etc/sv/udhcpc-eth0 /etc/service/udhcpc-eth0

    # WiFi: config template (private), service ready but not enabled
    mkdir -p /etc/wpa_supplicant
    if [ ! -f /etc/wpa_supplicant/wpa_supplicant.conf ]; then
        cat > /etc/wpa_supplicant/wpa_supplicant.conf <<'EOF'
# Add networks with:  wpa_passphrase "SSID" >> /etc/wpa_supplicant/wpa_supplicant.conf
ctrl_interface=DIR=/run/wpa_supplicant GROUP=root
update_config=1
# privacy: random MAC per network, random MAC while scanning
mac_addr=1
preassoc_mac_addr=1
gas_rand_mac_addr=1
EOF
        chmod 600 /etc/wpa_supplicant/wpa_supplicant.conf
    fi
    mkdir -p /etc/sv/wpa_supplicant
    cat > /etc/sv/wpa_supplicant/run <<'EOF'
#!/bin/sh
exec wpa_supplicant -i wlan0 -D nl80211 -c /etc/wpa_supplicant/wpa_supplicant.conf
EOF
    chmod 755 /etc/sv/wpa_supplicant/run
}

s_check() {
    openssl version
    curl --version | head -n1
    git --version
    wpa_supplicant -v | head -n1
    mke2fs -V 2>&1 | head -n1
    perl -v | sed -n 2p
    [ "$(readlink -f /usr/bin/busybox)" = /usr/bin/busybox ] && [ -x /usr/bin/busybox ]
}

# ---------------- run ----------------

run_step 30-zlib        s_zlib
run_step 31-e2fsprogs   s_e2fsprogs
run_step 32-perl        s_perl
run_step 33-openssl     s_openssl
run_step 34-cacerts     s_cacerts
run_step 35-curl        s_curl
run_step 36-git         s_git
run_step 36a-bison      s_bison
run_step 36b-flex       s_flex
run_step 37-libnl       s_libnl
run_step 38-wpa         s_wpa
run_step 39-network     s_network
run_step 40-check       s_check

echo
cat "$LOGS/40-check.log"
echo
info "Essentials finished. Exit, unmount, boot the VM, then test:"
info "  sv status /etc/service/*     ip addr     curl -I https://kernel.org"
