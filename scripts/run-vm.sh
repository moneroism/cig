#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 moneroism
# run-vm.sh - boot the distro image in QEMU with UEFI (OVMF).
# Kernel messages also appear in this terminal (serial console),
# so errors can be copied from here.

set -euo pipefail

IMG="$HOME/lfs.img"
LFS=/mnt/lfs
VARS="$HOME/cig/ovmf-vars.fd"

die() { echo "!! $*" >&2; exit 1; }

[ -f "$IMG" ] || die "$IMG not found"
mountpoint -q "$LFS" && die "image is still mounted at $LFS. Run: sudo umount -R $LFS"

CODE=$(find /usr/share -name 'OVMF_CODE*.fd' 2>/dev/null | grep -v -i secboot | head -n1 || true)
VTPL=$(find /usr/share -name 'OVMF_VARS*.fd' 2>/dev/null | head -n1 || true)
if [ -n "$CODE" ] && [ -n "$VTPL" ]; then
    [ -f "$VARS" ] || cp "$VTPL" "$VARS"
    FW=(-drive "if=pflash,format=raw,readonly=on,file=$CODE"
        -drive "if=pflash,format=raw,file=$VARS")
else
    ONE=$(find /usr/share -name 'OVMF.fd' 2>/dev/null | head -n1 || true)
    [ -n "$ONE" ] || die "OVMF firmware not found. Install: sudo xbps-install -S edk2-ovmf"
    FW=(-bios "$ONE")
fi

DISP=()
case "${1:-}" in
    sdl) DISP=(-display sdl) ;;
    gtk) DISP=(-display gtk) ;;
    vnc) DISP=(-display vnc=127.0.0.1:0); echo "VNC on 127.0.0.1:5900 (connect with a VNC viewer)" ;;
    "")  ;;
    *)   die "usage: run-vm.sh [sdl|gtk|vnc]" ;;
esac

ACCEL=()
[ -w /dev/kvm ] && ACCEL=(-enable-kvm -cpu host) || echo "(no KVM access: running slow. Add yourself to the 'kvm' group.)"

exec qemu-system-x86_64 \
    -machine q35 "${ACCEL[@]}" -smp 4 -m 4G "${DISP[@]}" \
    "${FW[@]}" \
    -drive "file=$IMG,format=raw,if=none,id=disk" \
    -device ahci,id=ahci -device ide-hd,drive=disk,bus=ahci.0 \
    -device virtio-vga \
    -nic user,model=e1000e \
    -serial mon:stdio
