#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 moneroism
# build-base.sh - phase 3: final base system. Run INSIDE the chroot:
#     bash /sources/build-base.sh
#
# Rebuilds musl, binutils and gcc natively (nothing built by Void remains),
# builds a trimmed BusyBox and sinit, and writes the boot/init configuration:
#   sinit (PID 1) -> /bin/rc.init -> BusyBox runsvdir supervises services
# Safe to re-run: finished steps are skipped, a failed step restarts.

set -euo pipefail

export PATH=/usr/bin:/usr/sbin
export LC_ALL=POSIX
export MAKEFLAGS="-j$(nproc)"
umask 022

SRC=/sources
LOGS="$SRC/logs"
STAMPS="$SRC/.stamps"

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

unpack() { cd "$SRC"; rm -rf "$2"; tar xf "$1"; cd "$2"; }

# ---------------- preflight ----------------
[ "$(id -u)" -eq 0 ] || die "run as root inside the chroot"
[ -f /etc/.handed-to-root ] || die "this must run inside the chroot"
[ -f "$SRC/VERSIONS" ] || die "$SRC/VERSIONS missing"
. "$SRC/VERSIONS"
[ -n "${SINIT_TAG:-}" ] && [ -d "$SRC/sinit" ] || die "run prepare-base.sh on Void first"
mkdir -p "$LOGS" "$STAMPS"

# ---------------- toolchain, final ----------------

s_musl() {
    unpack "musl-$MUSL_VER.tar.gz" "musl-$MUSL_VER"
    ./configure --prefix=/usr
    make
    make install
    cd "$SRC"; rm -rf "musl-$MUSL_VER"
}

s_binutils() {
    unpack "binutils-$BINUTILS_VER.tar.xz" "binutils-$BINUTILS_VER"
    mkdir build; cd build
    ../configure --prefix=/usr --sysconfdir=/etc \
        --enable-ld=default --enable-plugins --enable-shared \
        --disable-werror --disable-nls --enable-gprofng=no \
        --enable-64-bit-bfd --enable-new-dtags --enable-default-hash-style=gnu
    make tooldir=/usr MAKEINFO=true
    make tooldir=/usr MAKEINFO=true install
    cd "$SRC"; rm -rf "binutils-$BINUTILS_VER"
}

s_gcc() {
    [ -d "$SRC/gcc-$GCC_VER" ] || { echo "gcc source tree missing"; exit 1; }
    # gcc's option generator needs GNU awk; BusyBox awk produces broken output
    ln -sf gawk /usr/bin/awk
    awk --version | grep -q 'GNU Awk' || { echo "awk is not GNU awk"; exit 1; }
    cd "$SRC/gcc-$GCC_VER"
    rm -rf build4; mkdir build4; cd build4
    ../configure --prefix=/usr LD=ld \
        --enable-languages=c,c++ \
        --enable-default-pie --enable-default-ssp \
        --enable-host-pie --enable-host-bind-now \
        --enable-shared --enable-threads=posix --enable-tls --enable-__cxa_atexit \
        --disable-multilib --disable-bootstrap --disable-fixincludes \
        --disable-nls --disable-libsanitizer --disable-libssp --disable-libvtv \
        --disable-symvers --disable-libstdcxx-pch
    make MAKEINFO=true
    make MAKEINFO=true install
    ln -sf gcc /usr/bin/cc
    # let binutils use gcc's LTO plugin
    local plugin
    plugin=$(gcc -print-prog-name=liblto_plugin.so)
    mkdir -p /usr/lib/bfd-plugins
    ln -sf "$plugin" /usr/lib/bfd-plugins/
}

s_test_gcc() {
    cd /tmp
    printf 'int main(void){return 0;}\n' > t.c
    cc t.c -o t
    ./t
    readelf -l t | grep -q '/lib/ld-musl-x86_64.so.1'
    readelf -h t | grep -q 'DYN'            # PIE by default
    rm -f t t.c
}

s_cleanup_toolchain() {
    rm -rf /tools
    find /usr/lib -name '*.la' -delete
}

# ---------------- BusyBox, trimmed ----------------

BB_DISABLE="
TC SHA1_HWACCEL SHA256_HWACCEL LINUXRC
INIT FEATURE_SUID SU CRONTAB CROND
HTTPD TELNETD TELNET FTPD FTPGET FTPPUT TFTP TFTPD INETD
UDHCPD DHCPRELAY DUMPLEASES FAKEIDENTD
SENDMAIL POPMAILDIR REFORMIME MAKEMIME LPD LPR LPQ
SSL_CLIENT FEATURE_WGET_HTTPS TLS
"

s_busybox() {
    unpack "busybox-$BUSYBOX_VER.tar.bz2" "busybox-$BUSYBOX_VER"
    make defconfig
    local o
    for o in $BB_DISABLE; do
        sed -i "s/^CONFIG_$o=y\$/# CONFIG_$o is not set/" .config
    done
    make

    # BusyBox's own "make install" deletes each link and recreates it with
    # ln - which, inside this system, IS one of those links. So we install
    # by hand, always calling the new binary by its full path.
    local B=/usr/bin/busybox
    cp busybox /usr/bin/busybox.new
    mv -f /usr/bin/busybox.new "$B"

    # 1. remove links to applets that were trimmed out
    "$B" --list > /tmp/bb.list
    local d f
    for d in /usr/bin /usr/sbin; do
        for f in "$d"/*; do
            [ -L "$f" ] || continue
            case "$("$B" readlink "$f")" in *busybox) ;; *) continue ;; esac
            "$B" grep -Fqx "${f##*/}" /tmp/bb.list || "$B" rm -f "$f"
        done
    done
    "$B" rm -f /tmp/bb.list

    # 2. create links for every applet, never touching real files
    #    (bash, gawk, make...) or links that point somewhere else
    local p
    "$B" --list-full > /tmp/bb.paths
    while read -r p; do
        [ -n "$p" ] || continue
        p="/${p#/}"
        [ -L "$p" ] && continue       # existing link: busybox or deliberate (sh, awk)
        [ -e "$p" ] && continue       # real program: leave it
        "$B" ln -s /usr/bin/busybox "$p"
    done < /tmp/bb.paths
    "$B" rm -f /tmp/bb.paths

    "$B" ln -sf bash /usr/bin/sh     # bash stays /bin/sh while building
    "$B" ln -sf gawk /usr/bin/awk    # GNU awk stays awk (build scripts need it)
    cp .config "$SRC/busybox.config"
    cd "$SRC"; rm -rf "busybox-$BUSYBOX_VER"
}

# ---------------- sinit ----------------

s_sinit() {
    cd "$SRC/sinit"
    make clean || true
    cp config.def.h config.h     # defaults: /bin/rc.init, /bin/rc.shutdown
    make CC=cc
    make PREFIX=/usr install
}

# ---------------- system configuration ----------------

s_config() {
    mkdir -p /var/log /var/tmp /etc/sv /etc/service
    chmod 1777 /var/tmp

    # --- startup: run by sinit ---
    cat > /usr/bin/rc.init <<'EOF'
#!/bin/sh
# rc.init - system startup, started by sinit (PID 1)
PATH=/usr/bin:/usr/sbin
umask 022

mountpoint -q /proc || mount -t proc     -o nosuid,nodev,noexec proc /proc
mountpoint -q /sys  || mount -t sysfs    -o nosuid,nodev,noexec sysfs /sys
mountpoint -q /dev  || mount -t devtmpfs -o nosuid,mode=0755 devtmpfs /dev
mkdir -p /dev/pts /dev/shm
mount -t devpts -o nosuid,noexec,gid=5,mode=0620 devpts /dev/pts
mount -t tmpfs  -o nosuid,nodev,noexec,mode=1777 tmpfs /dev/shm
mount -t tmpfs  -o nosuid,nodev,mode=0755 tmpfs /run

mount -o remount,rw /
mount -a

hostname -F /etc/hostname
hwclock -s -u 2>/dev/null
ip link set lo up
sysctl -q -p /etc/sysctl.conf

# hardware: hotplug daemon, then load drivers for devices already present
mdev -d
for m in $(find /sys/devices -name modalias -exec cat {} + 2>/dev/null | sort -u); do
    modprobe -q "$m" 2>/dev/null
done
mdev -s

# optional: forbid loading any further kernel modules until reboot
[ -f /etc/lock-modules ] && echo 1 > /proc/sys/kernel/modules_disabled

# services (gettys, later iwd/seatd...) are supervised by runsvdir
runsvdir -P /etc/service &
EOF

    # --- shutdown: run by sinit on SIGUSR1 (poweroff) / SIGINT (reboot) ---
    cat > /usr/bin/rc.shutdown <<'EOF'
#!/bin/sh
# rc.shutdown - called by sinit with "poweroff" or "reboot"
PATH=/usr/bin:/usr/sbin
killall5 -15; sleep 2; killall5 -9
hwclock -w -u 2>/dev/null
sync
umount -a -r -t ext4,vfat,tmpfs 2>/dev/null   # real filesystems only, keep /proc
mount -o remount,ro / 2>/dev/null
sync
# call BusyBox directly: plain "poweroff" is our wrapper that signals sinit,
# which would start rc.shutdown again (endless loop)
case "$1" in
    reboot) busybox reboot -f ;;
    *)      busybox poweroff -f ;;
esac
EOF
    chmod 755 /usr/bin/rc.init /usr/bin/rc.shutdown

    # BusyBox's poweroff/reboot signal init in a way sinit ignores,
    # so the user-facing commands send sinit's signals instead.
    rm -f /usr/sbin/poweroff /usr/sbin/reboot /usr/sbin/halt
    printf '#!/bin/sh\nexec kill -USR1 1\n' > /usr/sbin/poweroff
    printf '#!/bin/sh\nexec kill -INT 1\n'  > /usr/sbin/reboot
    chmod 755 /usr/sbin/poweroff /usr/sbin/reboot

    # --- console logins, supervised ---
    local t
    for t in tty1 tty2; do
        mkdir -p "/etc/sv/getty-$t"
        printf '#!/bin/sh\nexec getty 38400 %s linux\n' "$t" > "/etc/sv/getty-$t/run"
        chmod 755 "/etc/sv/getty-$t/run"
        ln -sfn "/etc/sv/getty-$t" "/etc/service/getty-$t"
    done

    # --- filesystems ---
    cat > /etc/fstab <<'EOF'
# device      mount  type   options                                  dump pass
LABEL=root    /      ext4   defaults,noatime                         0    1
LABEL=home    /home  ext4   defaults,noatime,nodev,nosuid            0    2
LABEL=ESP     /boot  vfat   noauto,nodev,nosuid,noexec,umask=0077    0    0
tmpfs         /tmp   tmpfs  nosuid,nodev,noexec,mode=1777            0    0
EOF

    # --- device permissions + driver loading on hotplug ---
    cat > /etc/mdev.conf <<'EOF'
$MODALIAS=.*  root:root 0660 @modprobe -q "$MODALIAS"
null          root:root 0666
zero          root:root 0666
full          root:root 0666
random        root:root 0666
urandom       root:root 0666
tty           root:tty  0666
ptmx          root:tty  0666
dri/.*        root:video 0660
snd/.*        root:audio 0660
input/.*      root:input 0660
EOF

    # --- kernel hardening ---
    cat > /etc/sysctl.conf <<'EOF'
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1
kernel.printk = 3 3 3 3
kernel.unprivileged_bpf_disabled = 1
net.core.bpf_jit_harden = 2
kernel.yama.ptrace_scope = 2
kernel.kexec_load_disabled = 1
kernel.sysrq = 0
kernel.perf_event_paranoid = 3
kernel.unprivileged_userns_clone = 0
dev.tty.ldisc_autoload = 0
fs.protected_symlinks = 1
fs.protected_hardlinks = 1
fs.protected_fifos = 2
fs.protected_regular = 2
fs.suid_dumpable = 0
vm.mmap_rnd_bits = 32
vm.mmap_rnd_compat_bits = 16
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_rfc1337 = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv6.conf.all.use_tempaddr = 2
net.ipv6.conf.default.use_tempaddr = 2
net.ipv4.icmp_echo_ignore_all = 1
net.ipv4.ping_group_range = 0 2147483647
EOF

    # --- identity, users, shell ---
    [ -s /etc/hostname ] || echo distro > /etc/hostname
    cat > /etc/group <<'EOF'
root:x:0:
tty:x:5:
audio:x:11:
video:x:12:
input:x:24:
users:x:100:
nogroup:x:65534:
EOF
    if [ ! -f /etc/shadow ]; then
        echo 'root:!:20000:0:99999:7:::' > /etc/shadow
        chmod 600 /etc/shadow
    fi
    printf '/bin/sh\n/bin/bash\n' > /etc/shells
    cat > /etc/profile <<'EOF'
export PATH=/usr/bin:/usr/sbin
umask 027
PS1='\u@\h:\w\$ '
EOF
}

# ---------------- run ----------------

run_step 20-musl-final       s_musl
run_step 21-binutils-final   s_binutils
run_step 22-gcc-final        s_gcc
run_step 23-test-gcc         s_test_gcc
run_step 24-cleanup-tools    s_cleanup_toolchain
run_step 25-busybox-final    s_busybox
run_step 26-sinit            s_sinit
run_step 27-config           s_config

# ---------------- accounts (interactive) ----------------
if grep -q '^root:!:' /etc/shadow; then
    echo
    info "set the ROOT password:"
    passwd root
fi
if ! awk -F: '$3 >= 1000 && $3 < 65534 { found=1 } END { exit !found }' /etc/passwd; then
    echo
    printf '==> name for your normal user: '
    read -r NEWUSER
    adduser -D -s /bin/bash "$NEWUSER"
    for g in audio video input users; do addgroup "$NEWUSER" "$g"; done
    info "set the password for $NEWUSER:"
    passwd "$NEWUSER"
fi

echo
info "Base system finished."
info "Next (on Void, after 'exit'): install kernel, modules, firmware and boot entry."
