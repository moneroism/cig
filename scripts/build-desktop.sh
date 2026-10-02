#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 moneroism
# build-desktop.sh - phase 6 (round B), run INSIDE the chroot:
#     bash /sources/build-desktop.sh
#
# gperf, freetype, fontconfig, JetBrains Mono, tllist, fcft, foot, fuzzel,
# dwl 0.8 (monochrome, 3px grey borders), and the session:
# seatd service, /run/user/<uid> at boot, and the "startdwl" command.

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
    find "$S" -name '*.la' -delete
    ( cd "$S" && find . ! -type d ) | while read -r f; do
        t="/${f#./}"
        if [ -L "$t" ]; then case "$(readlink "$t")" in *busybox) rm -f "$t" ;; esac; fi
    done
    cp -a "$S/." /
    rm -rf "$S"
}

# keep only -D options this package version actually defines; report the rest
# (upstreams rename/drop options between releases)
known_opts() {
    local a name f keep=()
    f=$(ls meson_options.txt meson.options 2>/dev/null | head -n1 || true)
    for a in "$@"; do
        case "$a" in
            -D*=*)
                name=${a#-D}; name=${name%%=*}
                if [ -n "$f" ] && ! grep -qE "option\(['\"]$name['\"]" "$f"; then
                    echo "   (skipping option not defined by this version: $a)" >&2
                    continue
                fi ;;
        esac
        keep+=("$a")
    done
    printf '%s\n' "${keep[@]}"
}

meson_pkg() {
    local opts=()
    [ $# -gt 0 ] && mapfile -t opts < <(known_opts "$@")
    LDFLAGS="$HARDEN_LDFLAGS" meson setup build --prefix=/usr --libdir=lib \
        --buildtype=release --wrap-mode=nodownload "${opts[@]}"
    ninja -C build
    rm -rf "$S"; DESTDIR="$S" meson install -C build --no-rebuild
    stage_install
}

auto_pkg() {
    ./configure --prefix=/usr --disable-static LDFLAGS="$HARDEN_LDFLAGS" "$@"
    make
    rm -rf "$S"; make DESTDIR="$S" install
    stage_install
}

[ "$(id -u)" -eq 0 ] || die "run as root inside the chroot"
[ -f /etc/.handed-to-root ] || die "this must run inside the chroot"
. "$SRC/VERSIONS"
[ -n "${FOOT_VER:-}" ] || die "run prepare-desktop.sh on the host first"
pkg-config --exists "wlroots-0.19" || die "wlroots 0.19 missing (run build-wayland.sh)"
mkdir -p "$LOGS" "$STAMPS"

# ---------------- fonts ----------------

s_gperf() { unpack "gperf-$GPERF_VER.tar.gz"; auto_pkg; cleanup; }

s_freetype() {
    unpack "freetype-$FREETYPE_VER.tar.xz"
    meson_pkg -Dbrotli=disabled -Dbzip2=disabled -Dharfbuzz=disabled \
        -Dpng=disabled -Dzlib=enabled -Dtests=disabled
    cleanup
}

s_fontconfig() {
    unpack "fontconfig-$FONTCONFIG_VER.tar.xz"
    meson_pkg -Ddoc=disabled -Dtests=disabled -Dnls=disabled -Dcache-build=disabled
    cleanup
}

s_jbmono() {
    rm -rf /tmp/jb; mkdir -p /tmp/jb; cd /tmp/jb
    unzip -q "$SRC/JetBrainsMono-$JBMONO_VER.zip"
    install -d /usr/share/fonts/jetbrains-mono
    find . -path '*ttf*' -name '*.ttf' ! -path '*variable*' \
        -exec install -m 644 {} /usr/share/fonts/jetbrains-mono/ \;
    [ -n "$(ls /usr/share/fonts/jetbrains-mono)" ] || { echo "no TTF files found in zip"; exit 1; }
    cd /; rm -rf /tmp/jb
    fc-cache -f
}

# ---------------- text rendering, terminal, launcher ----------------

s_tllist() { unpack "tllist-$TLLIST_VER.tar.gz"; meson_pkg; cleanup; }

s_fcft() {
    unpack "fcft-$FCFT_VER.tar.gz"
    meson_pkg -Ddocs=disabled -Dgrapheme-shaping=disabled -Drun-shaping=disabled \
        -Dpng-backend=none -Dsvg-backend=none -Dtest-text-shaping=false
    cleanup
}

s_foot() {
    unpack "foot-$FOOT_VER.tar.gz"
    meson_pkg -Ddocs=disabled -Dthemes=false -Dtests=false \
        -Dgrapheme-clustering=disabled \
        -Dterminfo=disabled -Ddefault-terminfo=xterm-256color
    cleanup
    install -d /etc/xdg/foot
    cat > /etc/xdg/foot/foot.ini <<'EOF'
font=JetBrains Mono:size=11
pad=6x6

[colors]
background=000000
foreground=d0d0d0
EOF
}

s_fuzzel() {
    unpack "fuzzel-$FUZZEL_VER.tar.gz"
    # man pages need scdoc; we ship no man pages. If this version has no
    # "docs" option, drop the doc/ subdirectory from the build instead.
    if ! grep -qE "option\(['\"]docs['\"]" meson_options.txt meson.options 2>/dev/null; then
        sed -i "/subdir('doc')/d" meson.build
    fi
    meson_pkg -Ddocs=disabled -Denable-cairo=disabled -Dpng-backend=none -Dsvg-backend=none
    cleanup
    install -d /etc/xdg/fuzzel
    cat > /etc/xdg/fuzzel/fuzzel.ini <<'EOF'
[main]
font=JetBrains Mono:size=11
terminal=foot

[colors]
background=000000ee
text=d0d0d0ff
match=ffffffff
selection=444444ff
selection-text=ffffffff
border=888888ff

[border]
width=3
radius=2
EOF
}

# ---------------- dwl ----------------

s_dwl() {
    unpack "dwl-v$DWL_VER.tar.gz"
    cp config.def.h config.h
    # monochrome: 3px grey borders, light grey focus, black background
    sed -i \
        -e 's/^\(static const unsigned int borderpx *= *\)[0-9]*;/\13;/' \
        -e 's/^\(static const float rootcolor\[\] *= *COLOR(\)0x[0-9a-fA-F]*/\10x000000ff/' \
        -e 's/^\(static const float bordercolor\[\] *= *COLOR(\)0x[0-9a-fA-F]*/\10x444444ff/' \
        -e 's/^\(static const float focuscolor\[\] *= *COLOR(\)0x[0-9a-fA-F]*/\10xbbbbbbff/' \
        -e 's/^\(static const float urgentcolor\[\] *= *COLOR(\)0x[0-9a-fA-F]*/\10xffffffff/' \
        -e 's/"wmenu-run"/"fuzzel"/' \
        config.h
    cp config.h "$SRC/dwl-config.h"        # keep a copy for the repo
    make PREFIX=/usr LDFLAGS="$HARDEN_LDFLAGS"
    rm -rf "$S"; make PREFIX=/usr DESTDIR="$S" install
    stage_install
    cleanup
}

# ---------------- session ----------------

s_session() {
    # seatd: hands GPU + input devices to members of "video", no logind
    mkdir -p /etc/sv/seatd/log /var/log/seatd
    printf '#!/bin/sh\nexec seatd -g video 2>&1\n' > /etc/sv/seatd/run
    printf '#!/bin/sh\nexec svlogd -tt /var/log/seatd\n' > /etc/sv/seatd/log/run
    chmod 755 /etc/sv/seatd/run /etc/sv/seatd/log/run
    ln -sfn /etc/sv/seatd /etc/service/seatd

    # /run/user/<uid> for every normal user, created at boot (no logind)
    if ! grep -q '/run/user' /usr/bin/rc.init; then
        python3 - <<'EOF'
p = "/usr/bin/rc.init"
s = open(p).read()
block = '''# per-user runtime directories (normally logind's job)
mkdir -p -m 0755 /run/user
awk -F: '$3 >= 1000 && $3 < 65534 {print $3, $4}' /etc/passwd | while read -r u g; do
    install -d -m 700 -o "$u" -g "$g" "/run/user/$u"
done

'''
marker = "# services"
s = s.replace(marker, block + marker, 1) if marker in s else s.replace("runsvdir", block + "runsvdir", 1)
open(p, "w").write(s)
EOF
    fi
    grep -q XDG_RUNTIME_DIR /etc/profile || cat >> /etc/profile <<'EOF'
[ -d "/run/user/$(id -u)" ] && export XDG_RUNTIME_DIR="/run/user/$(id -u)"
EOF

    # the start command
    cat > /usr/bin/startdwl <<'EOF'
#!/bin/sh
# startdwl - start the dwl session (run from a tty as your normal user)
[ -n "$XDG_RUNTIME_DIR" ] || export XDG_RUNTIME_DIR="/run/user/$(id -u)"
[ -d "$XDG_RUNTIME_DIR" ] || { echo "no $XDG_RUNTIME_DIR - reboot once so rc.init creates it"; exit 1; }
export LIBSEAT_BACKEND=seatd
export WLR_RENDERER=pixman
export WLR_NO_HARDWARE_CURSORS=1
exec dwl "$@" 2> "$XDG_RUNTIME_DIR/dwl.log"
EOF
    chmod 755 /usr/bin/startdwl
}

s_check() {
    dwl -v 2>&1 | head -n1 || true     # dwl -v exits with status 1 by design
    foot --version | head -n1
    fuzzel --version | head -n1
    fc-list | grep -ci 'jetbrains mono' | sed 's/^/JetBrains Mono font files: /'
}

run_step 80-gperf       s_gperf
run_step 81-freetype    s_freetype
run_step 82-fontconfig  s_fontconfig
run_step 83-jbmono      s_jbmono
run_step 84-tllist      s_tllist
run_step 85-fcft        s_fcft
run_step 86-foot        s_foot
run_step 87-fuzzel      s_fuzzel
run_step 88-dwl         s_dwl
run_step 89-session     s_session
run_step 90-check       s_check

echo
cat "$LOGS/90-check.log"
echo
info "Desktop finished. Exit, unmount, boot the VM, log in as your user and run: startdwl"
