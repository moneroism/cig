#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 moneroism
# build-buildtools.sh - phase 5, run INSIDE the chroot:
#     bash /sources/build-buildtools.sh
#
# pkgconf, samurai (as ninja), Python 3.13 (minimal), meson,
# service logging via svlogd, and a meson smoke test.

set -euo pipefail

export PATH=/usr/bin:/usr/sbin
export LC_ALL=POSIX
export MAKEFLAGS="-j$(nproc)"
umask 022

SRC=/sources
LOGS="$SRC/logs"
STAMPS="$SRC/.stamps"
S=/tmp/stage

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

stage_install() {
    local d f t
    for d in bin sbin lib lib64; do
        if [ -d "$S/$d" ] && [ ! -L "$S/$d" ]; then
            t=$d; [ "$d" = lib64 ] && t=lib
            mkdir -p "$S/usr/$t"; cp -a "$S/$d/." "$S/usr/$t/"; rm -rf "$S/$d"
        fi
    done
    ( cd "$S" && find . ! -type d ) | while read -r f; do
        t="/${f#./}"
        if [ -L "$t" ]; then case "$(readlink "$t")" in *busybox) rm -f "$t" ;; esac; fi
    done
    cp -a "$S/." /
    rm -rf "$S"
}

[ "$(id -u)" -eq 0 ] || die "run as root inside the chroot"
[ -f /etc/.handed-to-root ] || die "this must run inside the chroot"
. "$SRC/VERSIONS"
[ -n "${PY_VER:-}" ] || die "run prepare-buildtools.sh on the host first"
mkdir -p "$LOGS" "$STAMPS"

HARDEN_LDFLAGS="-Wl,-z,relro,-z,now"

# ---------------- packages ----------------

s_pkgconf() {
    unpack "pkgconf-$PKGCONF_VER.tar.xz" "pkgconf-$PKGCONF_VER"
    ./configure --prefix=/usr --disable-static LDFLAGS="$HARDEN_LDFLAGS"
    make
    rm -rf "$S"; make DESTDIR="$S" install
    ln -sf pkgconf "$S/usr/bin/pkg-config"
    find "$S" -name '*.la' -delete
    stage_install
    cd "$SRC"; rm -rf "pkgconf-$PKGCONF_VER"
}

s_samurai() {
    unpack "samurai-$SAMU_VER.tar.gz" "samurai-$SAMU_VER"
    # samurai's Makefile calls "c99" (the POSIX name); we only have cc/gcc
    make CC=cc LDFLAGS="$HARDEN_LDFLAGS"
    rm -rf "$S"; make CC=cc PREFIX=/usr DESTDIR="$S" install
    ln -sf samu "$S/usr/bin/ninja"
    stage_install
    cd "$SRC"; rm -rf "samurai-$SAMU_VER"
}

s_python() {
    unpack "Python-$PY_VER.tar.xz" "Python-$PY_VER"
    # build tool only: no pip, no test modules, no PGO
    ./configure --prefix=/usr --enable-shared \
        --without-ensurepip --disable-test-modules \
        --with-system-expat=no LDFLAGS="$HARDEN_LDFLAGS"
    make
    rm -rf "$S"; make DESTDIR="$S" install
    ln -sf python3 "$S/usr/bin/python"
    stage_install
    cd "$SRC"; rm -rf "Python-$PY_VER"
}

s_meson() {
    unpack "meson-$MESON_VER.tar.gz" "meson-$MESON_VER"
    local site
    site=$(python3 -c 'import sysconfig; print(sysconfig.get_paths()["purelib"])')
    rm -rf "$S"
    mkdir -p "$S$site" "$S/usr/bin"
    cp -a mesonbuild "$S$site/"
    cat > "$S/usr/bin/meson" <<'EOF'
#!/usr/bin/python3
import sys
from mesonbuild.mesonmain import main
sys.exit(main())
EOF
    chmod 755 "$S/usr/bin/meson"
    python3 -m compileall -q -s "$S" -p / "$S$site/mesonbuild"
    stage_install
    cd "$SRC"; rm -rf "meson-$MESON_VER"
}

# ---------------- service logging ----------------
# runsv pipes a service's output into its log/ service; svlogd writes it to
# /var/log/<service>/current (rotated). Nothing prints on the console anymore.

s_logging() {
    local svc
    install -d -m 750 /var/log
    for svc in udhcpc-eth0 udhcpc-wlan0 wpa_supplicant; do
        [ -d "/etc/sv/$svc" ] || continue
        # make the service send errors into the log as well
        sed -i 's/^exec \(.*\)$/exec \1 2>\&1/; s/ 2>&1 2>&1$/ 2>\&1/' "/etc/sv/$svc/run"
        mkdir -p "/etc/sv/$svc/log"
        install -d -m 750 "/var/log/$svc"
        printf '#!/bin/sh\nexec svlogd -tt /var/log/%s\n' "$svc" > "/etc/sv/$svc/log/run"
        chmod 755 "/etc/sv/$svc/log/run"
    done
}

# ---------------- checks ----------------

s_check() {
    python3 --version
    meson --version
    ninja --version
    pkg-config --version
    # smoke test: a tiny meson project, built with samurai
    rm -rf /tmp/mtest; mkdir -p /tmp/mtest; cd /tmp/mtest
    printf 'project(%s, %s)\nexecutable(%s, %s)\n' "'t'" "'c'" "'t'" "'t.c'" > meson.build
    printf 'int main(void){return 0;}\n' > t.c
    meson setup build >/dev/null
    ninja -C build >/dev/null
    ./build/t
    echo "meson + samurai: OK"
    cd /; rm -rf /tmp/mtest
}

run_step 50-pkgconf    s_pkgconf
run_step 51-samurai    s_samurai
run_step 52-python     s_python
run_step 53-meson      s_meson
run_step 54-logging    s_logging
run_step 55-check      s_check

echo
cat "$LOGS/55-check.log"
echo
info "Build tools finished. Next phase: the Wayland stack and dwl."
