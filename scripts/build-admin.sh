#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 moneroism
# build-admin.sh - step 1, run INSIDE the chroot:
#     bash /sources/build-admin.sh
#
#  - OpenDoas: members of "wheel" can run admin commands (doas poweroff, ...)
#  - upstream defaults: stock dwl config, no foot/fuzzel theming

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
[ -n "${DOAS_VER:-}" ] || die "run prepare-admin.sh on the host first"
mkdir -p "$LOGS" "$STAMPS"

# ---------------- doas ----------------

s_doas() {
    unpack "opendoas-$DOAS_VER.tar.xz"
    # no PAM: checks /etc/shadow directly. Timestamp: "persist" option works.
    CFLAGS="-O2 -std=gnu17" LDFLAGS="$HARDEN_LDFLAGS" \
        ./configure --prefix=/usr --without-pam --with-timestamp
    make
    rm -rf "$S"; make DESTDIR="$S" install
    stage_install
    chown root:root /usr/bin/doas
    chmod 4755 /usr/bin/doas          # the system's only setuid program
    cleanup
}

s_wheel() {
    grep -q '^wheel:' /etc/group || echo 'wheel:x:10:' >> /etc/group
    # every existing normal user joins wheel (the installer will ask later)
    awk -F: '$3 >= 1000 && $3 < 65534 {print $1}' /etc/passwd | while read -r u; do
        addgroup "$u" wheel 2>/dev/null || true
    done
    cat > /etc/doas.conf <<'EOF'
# members of wheel may run any command as root (password asked once per
# terminal, then remembered for a few minutes)
permit persist :wheel
EOF
    chown root:root /etc/doas.conf
    chmod 0400 /etc/doas.conf
    doas -C /etc/doas.conf && echo "doas.conf syntax OK"
}

# ---------------- upstream defaults ----------------

s_defaults() {
    # dwl: rebuild with its own unmodified config.def.h
    unpack "dwl-v$DWL_VER.tar.gz"
    cp config.def.h config.h
    cp config.h "$SRC/dwl-config.h"
    make PREFIX=/usr LDFLAGS="$HARDEN_LDFLAGS"
    rm -rf "$S"; make PREFIX=/usr DESTDIR="$S" install
    stage_install
    cleanup

    # foot: only a functional setting (users get their normal login environment)
    cat > /etc/xdg/foot/foot.ini <<'EOF'
login-shell=yes
EOF
    # fuzzel: no system config
    rm -rf /etc/xdg/fuzzel
}

s_check() {
    ls -l /usr/bin/doas
    grep '^wheel:' /etc/group
    grep -c 'COLOR(0x' "$SRC/dwl-config.h" | sed 's/^/stock dwl colour lines: /'
    cat /etc/xdg/foot/foot.ini
}

run_step 95-doas      s_doas
run_step 96-wheel     s_wheel
run_step 97-defaults  s_defaults
run_step 98-check     s_check

echo
cat "$LOGS/98-check.log"
echo
info "Done. In the VM, your user can now run:  doas poweroff"
