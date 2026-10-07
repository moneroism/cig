#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 moneroism
#
# build-initramfs.sh <folder> - the install medium's initramfs: BusyBox and musl from this
# system plus scripts/initramfs/init, and <folder>/initramfs.list describing them in the
# kernel's gen_init_cpio format. The medium's kernel is built with
# CIG_KERNEL_INITRAMFS=<folder> (scripts/build-media.sh shows the command).
#
# A list, not the folder itself: for a folder the kernel's usr/gen_initramfs.sh runs
# `find -printf` (GNU), which BusyBox find lacks, and the initramfs came out empty. The list
# also creates /dev/console without mknod (the kernel opens it before /init runs).
set -euo pipefail
REPO="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
OUT=${1:?usage: build-initramfs.sh <folder>}
OUT=$(mkdir -p "$OUT" && cd "$OUT" && pwd)
VERSION=$(cat "$REPO/VERSION")
BUSYBOX=${CIG_INITRAMFS_BUSYBOX:-/usr/bin/busybox}   # overrides: for testing on another system
LIBC=${CIG_INITRAMFS_LIBC:-/usr/lib/libc.so}

rm -rf "$OUT/files"
mkdir -p "$OUT/files"
cp -L "$BUSYBOX" "$OUT/files/busybox"
cp -L "$LIBC" "$OUT/files/libc.so"
cp "$REPO/scripts/initramfs/init" "$OUT/files/init"
echo "CIG_${VERSION//./_}" > "$OUT/files/medium-label"   # the ISO's volume label (build-media.sh)

F="$OUT/files"
cat > "$OUT/initramfs.list" <<EOF
dir /dev 755 0 0
nod /dev/console 600 0 0 c 5 1
nod /dev/null 666 0 0 c 1 3
dir /proc 755 0 0
dir /sys 755 0 0
dir /etc 755 0 0
dir /mnt 755 0 0
dir /mnt/medium 755 0 0
dir /usr 755 0 0
dir /usr/bin 755 0 0
dir /usr/lib 755 0 0
slink /bin usr/bin 777 0 0
slink /sbin usr/bin 777 0 0
slink /lib usr/lib 777 0 0
file /usr/bin/busybox $F/busybox 755 0 0
file /usr/lib/libc.so $F/libc.so 755 0 0
slink /usr/lib/ld-musl-x86_64.so.1 libc.so 777 0 0
file /etc/medium-label $F/medium-label 644 0 0
file /init $F/init 755 0 0
EOF
echo "initramfs list $OUT/initramfs.list ($(du -sh "$F" | cut -f1)), medium label $(cat "$F/medium-label")"
