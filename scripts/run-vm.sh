#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# run-vm.sh - boot the distro image in QEMU with UEFI (OVMF).
# Kernel messages also appear in this terminal (serial console),
# so errors can be copied from here.

set -euo pipefail

# CIG_IMG:    disk to boot (default ~/cig.img; none when CIG_CDROM is set)
# CIG_CDROM:  an ISO in a CD drive, booted first (the install medium)
# CIG_TARGET: optional second, empty disk, e.g. to test the installer
# CIG_VM_EXTRA:  more QEMU options, e.g. "-rtc base=2024-03-01T12:00:00" (a wrong clock)
# CIG_VM_MONITOR: a QEMU monitor on this unix socket (screendump, sendkey: tests without a
#             person at the VM window)
CDROM="${CIG_CDROM:-}"
if [ -n "$CDROM" ]; then IMG="${CIG_IMG:-}"; else IMG="${CIG_IMG:-$HOME/cig.img}"; fi
TARGET="${CIG_TARGET:-}"
SYS=/mnt/cig
VARS="$HOME/cig/ovmf-vars.fd"

die() { echo "!! $*" >&2; exit 1; }

[ -z "$IMG" ] || [ -f "$IMG" ] || die "$IMG not found"
[ -z "$CDROM" ] || [ -f "$CDROM" ] || die "$CDROM not found"
[ -z "$TARGET" ] || [ -f "$TARGET" ] || die "$TARGET not found (create it: qemu-img create -f raw $TARGET 40G)"
# the dev image must not be used by the chroot and the VM at once (an ISO or a target may)
[ "$IMG" != "$HOME/cig.img" ] || ! mountpoint -q "$SYS" || die "image is still mounted at $SYS. Run: sudo umount -R $SYS"

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
    none) DISP=(-display none) ;;   # headless: screenshots through CIG_VM_MONITOR
    "")  ;;
    *)   die "usage: run-vm.sh [sdl|gtk|vnc|none]" ;;
esac

ACCEL=()
[ -w /dev/kvm ] && ACCEL=(-enable-kvm -cpu host) || echo "(no KVM access: running slow. Add yourself to the 'kvm' group.)"

MON=()
[ -n "${CIG_VM_MONITOR:-}" ] && MON=(-monitor "unix:$CIG_VM_MONITOR,server,nowait")

DISKS=(-device ahci,id=ahci)
[ -n "$IMG" ] && DISKS+=(-drive "file=$IMG,format=raw,if=none,id=disk" -device ide-hd,drive=disk,bus=ahci.0,bootindex=0)
[ -n "$TARGET" ] && DISKS+=(-drive "file=$TARGET,format=raw,if=none,id=target" -device ide-hd,drive=target,bus=ahci.1)
[ -n "$CDROM" ] && DISKS+=(-drive "file=$CDROM,format=raw,if=none,id=cd,media=cdrom,readonly=on" -device ide-cd,drive=cd,bus=ahci.2,bootindex=0)

exec qemu-system-x86_64 \
    -machine q35 "${ACCEL[@]}" -smp 4 -m 4G "${DISP[@]}" \
    "${FW[@]}" \
    "${DISKS[@]}" "${MON[@]}" ${CIG_VM_EXTRA:-} \
    -device virtio-vga \
    -device qemu-xhci -device usb-tablet \
    -nic user,model=e1000e \
    -serial mon:stdio
