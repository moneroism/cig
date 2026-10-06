#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 moneroism
#
# build-initramfs.sh <folder> - the install medium's initramfs: BusyBox and musl from this
# system plus scripts/initramfs/init. Run inside cig as root (the dev chroot); the medium's
# kernel is then built with it (scripts/build-media.sh shows the command).
set -euo pipefail
REPO="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
OUT=${1:?usage: build-initramfs.sh <folder>}
VERSION=$(cat "$REPO/VERSION")
die() { echo "!! build-initramfs: $*" >&2; exit 1; }
[ "$(id -u)" -eq 0 ] || die "run as root (inside the dev chroot)"

rm -rf "$OUT"
mkdir -p "$OUT"/{usr/bin,usr/lib,etc,dev,proc,sys,mnt/medium}
ln -s usr/bin "$OUT/bin"; ln -s usr/lib "$OUT/lib"; ln -s usr/bin "$OUT/sbin"
cp -L /usr/bin/busybox "$OUT/usr/bin/busybox"
cp -L /usr/lib/libc.so "$OUT/usr/lib/libc.so"
ln -s libc.so "$OUT/usr/lib/ld-musl-x86_64.so.1"
# the kernel opens /dev/console in the initramfs before /init runs (devtmpfs comes later):
# without it init has no screen ("unable to open an initial console")
mknod -m 600 "$OUT/dev/console" c 5 1
mknod -m 666 "$OUT/dev/null" c 1 3
install -m 755 "$REPO/scripts/initramfs/init" "$OUT/init"
echo "CIG_${VERSION//./_}" > "$OUT/etc/medium-label"   # the ISO's volume label (build-media.sh)
echo "initramfs in $OUT ($(du -sh "$OUT" | cut -f1)), medium label $(cat "$OUT/etc/medium-label")"
