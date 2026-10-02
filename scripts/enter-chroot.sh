#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 moneroism
# enter-chroot.sh - enter the new system (run with sudo)
#
# First run: hands /mnt/lfs over to root and creates the minimal files a
# system needs (/etc/passwd, /etc/group, /tmp, ...).
# Every run: mounts /dev, /proc, /sys, /run inside /mnt/lfs, opens a shell
# inside the new system, and unmounts everything again when you exit.

set -euo pipefail

LFS=/mnt/lfs

die() { echo "!! $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "run with sudo"
mountpoint -q "$LFS" || die "$LFS is not mounted"
[ -x "$LFS/usr/bin/gcc" ] || die "temporary system not built yet (run build-temp.sh)"

# ---- one-time handover ----
if [ ! -f "$LFS/etc/.handed-to-root" ]; then
    echo "==> first run: handing $LFS over to root"
    chown -R root:root "$LFS"/{usr,var,etc,tools,sources}
    mkdir -p "$LFS"/{dev,proc,sys,run,root,tmp,home}
    chmod 0750 "$LFS/root"
    chmod 1777 "$LFS/tmp"

    cat > "$LFS/etc/passwd" <<'EOF'
root:x:0:0:root:/root:/bin/bash
nobody:x:65534:65534:nobody:/:/bin/false
EOF
    cat > "$LFS/etc/group" <<'EOF'
root:x:0:
tty:x:5:
nogroup:x:65534:
EOF
    cat > "$LFS/etc/hosts" <<'EOF'
127.0.0.1 localhost
::1       localhost
EOF
    ln -sf /proc/self/mounts "$LFS/etc/mtab"
    touch "$LFS/etc/.handed-to-root"
fi

# ---- mount virtual filesystems ----
cleanup() {
    for m in dev/shm dev/pts dev proc sys run; do
        mountpoint -q "$LFS/$m" && umount "$LFS/$m" || true
    done
}
trap cleanup EXIT

mountpoint -q "$LFS/dev"     || mount --bind /dev "$LFS/dev"
mountpoint -q "$LFS/dev/pts" || mount -t devpts devpts -o gid=5,mode=0620 "$LFS/dev/pts"
mountpoint -q "$LFS/proc"    || mount -t proc proc "$LFS/proc"
mountpoint -q "$LFS/sys"     || mount -t sysfs sysfs "$LFS/sys"
mountpoint -q "$LFS/run"     || mount -t tmpfs -o nosuid,nodev tmpfs "$LFS/run"
if [ ! -L "$LFS/dev/shm" ]; then
    mkdir -p "$LFS/dev/shm"
    mountpoint -q "$LFS/dev/shm" || mount -t tmpfs -o nosuid,nodev tmpfs "$LFS/dev/shm"
fi

# ---- enter ----
echo "==> entering the new system. Type 'exit' to leave."
chroot "$LFS" /usr/bin/env -i \
    HOME=/root TERM="${TERM:-xterm}" \
    PS1='(distro) \u:\w\$ ' \
    PATH=/usr/bin:/usr/sbin \
    MAKEFLAGS="-j$(nproc)" \
    /bin/bash --login
