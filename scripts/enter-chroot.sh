#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# enter-chroot.sh - enter the new system (run with sudo)
#
# First run: hands /mnt/cig over to root and creates the minimal files a
# system needs (/etc/passwd, /etc/group, /tmp, ...).
# Every run: mounts /dev, /proc, /sys, /run inside /mnt/cig, opens a shell
# inside the new system, and unmounts everything again when you exit.
#
#   enter-chroot.sh                 interactive shell
#   enter-chroot.sh -c "<command>"  run one command inside, then leave

set -euo pipefail

SYS=/mnt/cig
REPO="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"   # the cig repository

die() { echo "!! $*" >&2; exit 1; }

CMD=()
case "${1:-}" in
    -c) [ $# -eq 2 ] || die "usage: enter-chroot.sh [-c \"<command>\"]"; CMD=(-c "$2") ;;
    "") ;;
    *)  die "usage: enter-chroot.sh [-c \"<command>\"]" ;;
esac

[ "$(id -u)" -eq 0 ] || die "run with sudo"
mountpoint -q "$SYS" || die "$SYS is not mounted"
[ -x "$SYS/usr/bin/gcc" ] || [ -L "$SYS/usr/bin/gcc" ] || die "temporary system not built yet (run build-temp.sh)"

# ---- one-time handover ----
if [ ! -f "$SYS/etc/.handed-to-root" ]; then
    echo "==> first run: handing $SYS over to root"
    chown -R root:root "$SYS"/{usr,var,etc,tools,sources}
    mkdir -p "$SYS"/{dev,proc,sys,run,root,tmp,home}
    chmod 0750 "$SYS/root"
    chmod 1777 "$SYS/tmp"

    cat > "$SYS/etc/passwd" <<'EOF'
root:x:0:0:root:/root:/bin/bash
nobody:x:65534:65534:nobody:/:/bin/false
EOF
    cat > "$SYS/etc/group" <<'EOF'
root:x:0:
tty:x:5:
nogroup:x:65534:
EOF
    cat > "$SYS/etc/hosts" <<'EOF'
127.0.0.1 localhost
::1       localhost
EOF
    ln -sf /proc/self/mounts "$SYS/etc/mtab"
    touch "$SYS/etc/.handed-to-root"
fi

# ---- mount virtual filesystems ----
cleanup() {
    for m in boot etc/resolv.conf cig dev/shm dev/pts dev proc sys run; do
        grep -q " $SYS/$m " /proc/mounts && umount "$SYS/$m" || true
    done
}
trap cleanup EXIT

mountpoint -q "$SYS/dev"     || mount --bind /dev "$SYS/dev"
mountpoint -q "$SYS/dev/pts" || mount -t devpts devpts -o gid=5,mode=0620 "$SYS/dev/pts"
mountpoint -q "$SYS/proc"    || mount -t proc proc "$SYS/proc"
mountpoint -q "$SYS/sys"     || mount -t sysfs sysfs "$SYS/sys"
mountpoint -q "$SYS/run"     || mount -t tmpfs -o nosuid,nodev tmpfs "$SYS/run"
if [ ! -L "$SYS/dev/shm" ]; then
    mkdir -p "$SYS/dev/shm"
    mountpoint -q "$SYS/dev/shm" || mount -t tmpfs -o nosuid,nodev tmpfs "$SYS/dev/shm"
fi

# the repository (cigbuild + recipes) appears as /cig inside the system
if [ -x "$REPO/cigbuild" ]; then
    mkdir -p "$SYS/cig"
    mountpoint -q "$SYS/cig" || mount --bind "$REPO" "$SYS/cig"
    ln -sfn /cig/cigbuild "$SYS/usr/bin/cigbuild"
    ln -sfn /cig/smoke "$SYS/usr/bin/smoke"
fi

# the EFI partition (partition 1 of the same disk) at /boot, for kernel installs
ROOTDEV=$(findmnt -no SOURCE "$SYS")
ESPDEV="${ROOTDEV%2}1"
if [ -b "$ESPDEV" ] && ! grep -q " $SYS/boot " /proc/mounts; then
    mount "$ESPDEV" "$SYS/boot"
fi

# downloads inside the chroot use the host's DNS (the image's own
# resolv.conf points at QEMU's DNS, which only exists inside the VM)
touch "$SYS/etc/resolv.conf"
grep -q " $SYS/etc/resolv.conf " /proc/mounts || mount --bind /etc/resolv.conf "$SYS/etc/resolv.conf"

# ---- enter ----
[ ${#CMD[@]} -gt 0 ] || echo "==> entering the new system. Type 'exit' to leave."
chroot "$SYS" /usr/bin/env -i \
    HOME=/root TERM="${TERM:-xterm}" \
    PS1='(distro) \u:\w\$ ' \
    PATH=/usr/bin:/usr/sbin:/cig \
    MAKEFLAGS="-j$(nproc)" \
    /bin/bash --login "${CMD[@]}"
