#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 moneroism
# build-wayland.sh - phase 6 (round A), run INSIDE the chroot:
#     bash /sources/build-wayland.sh
#
# Everything wlroots needs, then wlroots 0.19 itself:
#   CPU rendering (pixman) only - no Mesa, no LLVM, no GBM
#   DRM + libinput backends only - no X11, no Xwayland
#   seat access through seatd - no logind, no D-Bus

set -euo pipefail

export PATH=/usr/bin:/usr/sbin
export LC_ALL=POSIX
export MAKEFLAGS="-j$(nproc)"
umask 022

SRC=/sources
LOGS="$SRC/logs"
STAMPS="$SRC/.stamps"
S=/tmp/stage
HARDEN_LDFLAGS="-Wl,-z,relro,-z,now"

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

# unpack <tarball>: extract fresh, cd into whatever top folder it contains
unpack() {
    cd "$SRC"
    local top
    top=$(tar tf "$1" 2>/dev/null | sed 's#^\./##' | grep / | head -n1 | cut -d/ -f1 || true)
    [ -n "$top" ] || { echo "cannot read $1"; return 1; }
    rm -rf "$top"; tar xf "$1"; cd "$top"
    BUILD_DIR="$SRC/$top"
}
cleanup() { cd "$SRC"; rm -rf "$BUILD_DIR"; }

stage_install() {
    local d f t
    for d in bin sbin lib lib64; do
        if [ -d "$S/$d" ] && [ ! -L "$S/$d" ]; then
            t=$d; [ "$d" = lib64 ] && t=lib
            mkdir -p "$S/usr/$t"; cp -a "$S/$d/." "$S/usr/$t/"; rm -rf "$S/$d"
        fi
    done
    find "$S" -name '*.la' -delete
    ( cd "$S" && find . ! -type d ) | while read -r f; do
        t="/${f#./}"
        if [ -L "$t" ]; then case "$(readlink "$t")" in *busybox) rm -f "$t" ;; esac; fi
    done
    cp -a "$S/." /
    rm -rf "$S"
}

# meson_pkg <meson options...>: configure, build, install via staging
meson_pkg() {
    LDFLAGS="$HARDEN_LDFLAGS" meson setup build --prefix=/usr --libdir=lib \
        --buildtype=release --wrap-mode=nodownload "$@"
    ninja -C build
    rm -rf "$S"; DESTDIR="$S" meson install -C build --no-rebuild
    stage_install
}

# auto_pkg <configure options...>: autotools, same flow
auto_pkg() {
    ./configure --prefix=/usr --disable-static LDFLAGS="$HARDEN_LDFLAGS" "$@"
    make
    rm -rf "$S"; make DESTDIR="$S" install
    stage_install
}

[ "$(id -u)" -eq 0 ] || die "run as root inside the chroot"
[ -f /etc/.handed-to-root ] || die "this must run inside the chroot"
. "$SRC/VERSIONS"
[ -n "${WLROOTS_VER:-}" ] || die "run prepare-wayland.sh on the host first"
command -v meson >/dev/null || die "build tools missing (run build-buildtools.sh)"
mkdir -p "$LOGS" "$STAMPS"

# ---------------- packages ----------------

s_libffi() { unpack "libffi-$LIBFFI_VER.tar.gz"; auto_pkg --with-gcc-arch=x86-64; cleanup; }

s_expat() {
    unpack "expat-$EXPAT_VER.tar.xz"
    auto_pkg --without-docbook --without-examples --without-tests
    cleanup
}

s_wayland() {
    unpack "wayland-$WAYLAND_VER.tar.xz"
    meson_pkg -Ddocumentation=false -Dtests=false -Ddtd_validation=false
    cleanup
}

s_protocols() {
    unpack "wayland-protocols-$PROTOCOLS_VER.tar.xz"
    meson_pkg -Dtests=false
    cleanup
}

s_libdrm() {
    unpack "libdrm-$LIBDRM_VER.tar.xz"
    # core + amdgpu (for the RX570 later); every other vendor off
    meson_pkg -Damdgpu=enabled -Dintel=disabled -Dradeon=disabled -Dnouveau=disabled \
        -Dvmwgfx=disabled -Dfreedreno=disabled -Dvc4=disabled -Detnaviv=disabled \
        -Dexynos=disabled -Domap=disabled -Dtegra=disabled \
        -Dvalgrind=disabled -Dcairo-tests=disabled -Dman-pages=disabled \
        -Dtests=false -Dudev=false
    cleanup
}

s_pixman() {
    unpack "pixman-$PIXMAN_VER.tar.xz"
    meson_pkg -Dgtk=disabled -Dlibpng=disabled -Dtests=disabled -Ddemos=disabled
    cleanup
}

s_xkbconfig() {
    unpack "xkeyboard-config-$XKBCONFIG_VER.tar.xz"
    meson_pkg
    cleanup
}

s_xkbcommon() {
    unpack "libxkbcommon-$XKBCOMMON_VER.tar.gz"
    meson_pkg -Denable-x11=false -Denable-docs=false -Denable-tools=false \
        -Denable-xkbregistry=false -Denable-bash-completion=false \
        -Dxkb-config-root=/usr/share/X11/xkb
    cleanup
}

s_mtdev() { unpack "mtdev-$MTDEV_VER.tar.bz2"; auto_pkg; cleanup; }

s_libevdev() {
    unpack "libevdev-$LIBEVDEV_VER.tar.xz"
    meson_pkg -Dtests=disabled -Ddocumentation=disabled
    cleanup
}

s_c99() {
    # POSIX "c99" compiler command; some small C projects call it by that name
    printf '#!/bin/sh\nexec cc -std=c99 "$@"\n' > /usr/bin/c99
    chmod 755 /usr/bin/c99
}

s_udevzero() {
    unpack "libudev-zero-$UDEVZERO_VER.tar.gz"
    make PREFIX=/usr LDFLAGS="$HARDEN_LDFLAGS"
    rm -rf "$S"; make PREFIX=/usr DESTDIR="$S" install
    rm -f "$S"/usr/lib/*.a
    stage_install
    cleanup
}

s_libinput() {
    unpack "libinput-$LIBINPUT_VER.tar.gz"
    meson_pkg -Dlibwacom=false -Ddebug-gui=false -Dtests=false -Ddocumentation=false
    cleanup
}

s_seatd() {
    unpack "seatd-$SEATD_VER.tar.gz"
    meson_pkg -Dlibseat-logind=disabled -Dlibseat-seatd=enabled -Dlibseat-builtin=enabled \
        -Dserver=enabled -Dexamples=disabled -Dman-pages=disabled
    cleanup
}

s_hwdata() {
    unpack "hwdata-$HWDATA_VER.tar.gz"
    ./configure --prefix=/usr --disable-blacklist
    rm -rf "$S"; make DESTDIR="$S" install
    stage_install
    cleanup
}

s_displayinfo() {
    unpack "libdisplay-info-$DISPLAYINFO_VER.tar.xz"
    meson_pkg
    cleanup
}

s_wlroots() {
    unpack "wlroots-$WLROOTS_VER.tar.gz"
    # pixman renderer only (CPU), no GBM allocator, no X11/Xwayland
    meson_pkg -Dxwayland=disabled -Dbackends=drm,libinput \
        -Drenderers=[] -Dallocators=[] -Dsession=enabled \
        -Dcolor-management=disabled -Dlibliftoff=disabled -Dexamples=false
    cleanup
}

s_check() {
    for p in wayland-server wayland-protocols libdrm pixman-1 xkbcommon libinput \
             libseat libdisplay-info "wlroots-${WLROOTS_VER%.*}"; do
        printf '%-20s %s\n' "$p" "$(pkg-config --modversion "$p")"
    done
}

run_step 60-libffi       s_libffi
run_step 61-expat        s_expat
run_step 62-wayland      s_wayland
run_step 63-protocols    s_protocols
run_step 64-libdrm       s_libdrm
run_step 65-pixman       s_pixman
run_step 66-xkbconfig    s_xkbconfig
run_step 67-xkbcommon    s_xkbcommon
run_step 68-mtdev        s_mtdev
run_step 69-libevdev     s_libevdev
run_step 69b-c99         s_c99
run_step 70-udevzero     s_udevzero
run_step 71-libinput     s_libinput
run_step 72-seatd        s_seatd
run_step 73-hwdata       s_hwdata
run_step 74-displayinfo  s_displayinfo
run_step 75-wlroots      s_wlroots
run_step 76-check        s_check

echo
cat "$LOGS/76-check.log"
echo
info "Wayland core finished. Next round: fonts, foot, fuzzel, dwl and the session."
