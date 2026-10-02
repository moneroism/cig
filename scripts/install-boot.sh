#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 moneroism
# install-boot.sh - make /mnt/lfs bootable. Run on VOID as your normal user
# (asks for sudo where needed). Exit the chroot before running this.
#
#  1. asks for the distro name (saved for next time)
#  2. rebuilds the kernel with the built-in, unchangeable command line
#  3. installs kernel (EFISTUB), signed modules, firmware into the image
#  4. writes os-release / issue / hostname
#  5. deletes the module signing key

set -euo pipefail

LFS=/mnt/lfs
KSRC="$HOME/cig/linux-hardened"
FWSRC="$HOME/cig/linux-firmware"
NAMEFILE="$HOME/cig/distro-name"

die()  { echo; echo "!! $*" >&2; exit 1; }
info() { echo "==> $*"; }

[ "$(id -u)" -ne 0 ] || die "run as your normal user, not root"
mountpoint -q "$LFS" || die "$LFS is not mounted"
mountpoint -q "$LFS/proc" && die "exit the chroot first"
[ -x "$LFS/usr/bin/sinit" ] || die "base system not finished (no sinit)"
[ -f "$KSRC/.config" ] || die "kernel tree not found at $KSRC"
[ -d "$FWSRC" ] || die "linux-firmware not found at $FWSRC"

# ---------- 1. name ----------
if [ -f "$NAMEFILE" ]; then
    . "$NAMEFILE"
else
    read -r -p "Display name (e.g. Ember Linux): " DISTRO_NAME
    read -r -p "ID, lowercase, no spaces (e.g. ember): " DISTRO_ID
    printf 'DISTRO_NAME=%q\nDISTRO_ID=%q\n' "$DISTRO_NAME" "$DISTRO_ID" > "$NAMEFILE"
fi
[[ "$DISTRO_ID" =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "ID must be lowercase letters, digits, dashes (edit $NAMEFILE)"
info "distro: $DISTRO_NAME ($DISTRO_ID)"

# ---------- 2. devices ----------
ROOTDEV=$(findmnt -no SOURCE "$LFS")
ESPDEV="${ROOTDEV%2}1"
PARTUUID=$(sudo blkid -s PARTUUID -o value "$ROOTDEV")
[ -n "$PARTUUID" ] || die "could not read PARTUUID of $ROOTDEV"
info "root: $ROOTDEV  PARTUUID=$PARTUUID   ESP: $ESPDEV"
mountpoint -q "$LFS/boot" || sudo mount "$ESPDEV" "$LFS/boot"

# ---------- 3. kernel ----------
CMDLINE="root=PARTUUID=$PARTUUID rootfstype=ext4 rootwait ro init=/usr/bin/sinit"
CMDLINE="$CMDLINE console=ttyS0,115200 console=tty0 loglevel=4"
CMDLINE="$CMDLINE slab_nomerge init_on_alloc=1 init_on_free=1 page_alloc.shuffle=1"
CMDLINE="$CMDLINE randomize_kstack_offset=on vsyscall=none debugfs=off"

info "configuring kernel"
cd "$KSRC"
scripts/config --enable CMDLINE_BOOL --set-str CMDLINE "$CMDLINE" \
    --enable CMDLINE_OVERRIDE \
    --set-str LOCALVERSION "-$DISTRO_ID" --disable LOCALVERSION_AUTO
make olddefconfig >/dev/null
info "building kernel (incremental; a few minutes)"
make -j"$(nproc)" >/tmp/kernel-build.log 2>&1 || { tail -n 30 /tmp/kernel-build.log; die "kernel build failed (log: /tmp/kernel-build.log)"; }
KVER=$(make -s kernelrelease)
mkdir -p "$HOME/cig/kernel"
cp .config "$HOME/cig/kernel/config-$KVER"
info "kernel $KVER built"

# ---------- 4. install kernel + modules ----------
info "installing modules (signed, stripped)"
sudo rm -rf "$LFS/usr/lib/modules/$KVER"
sudo make -s modules_install INSTALL_MOD_PATH="$LFS" INSTALL_MOD_STRIP=1

info "installing kernel to the ESP"
sudo mkdir -p "$LFS/boot/EFI/BOOT" "$LFS/boot/EFI/$DISTRO_ID"
if [ -f "$LFS/boot/EFI/$DISTRO_ID/vmlinuz.efi" ]; then
    sudo cp "$LFS/boot/EFI/$DISTRO_ID/vmlinuz.efi" "$LFS/boot/EFI/$DISTRO_ID/vmlinuz-old.efi"
fi
sudo cp arch/x86/boot/bzImage "$LFS/boot/EFI/$DISTRO_ID/vmlinuz.efi"
sudo cp arch/x86/boot/bzImage "$LFS/boot/EFI/BOOT/BOOTX64.EFI"   # UEFI fallback path

# no private key left behind = nobody can sign a module for this kernel
rm -f certs/signing_key.pem
info "module signing key deleted"

# ---------- 5. firmware ----------
info "installing firmware"
FWDST="$LFS/usr/lib/firmware"
sudo mkdir -p "$FWDST/amdgpu"
fw=$(find "$FWSRC" -name 'iwlwifi-7265D-29.ucode' | head -n1)
[ -n "$fw" ] || die "iwlwifi-7265D-29.ucode not found in $FWSRC"
sudo cp -L "$fw" "$FWDST/iwlwifi-7265D-29.ucode"
n=0
for f in $(find "$FWSRC" -path '*amdgpu/polaris10_*.bin'); do
    sudo cp -L "$f" "$FWDST/amdgpu/"; n=$((n+1))
done
[ "$n" -gt 0 ] || die "no amdgpu/polaris10_*.bin files found in $FWSRC"
( cd "$FWDST" && sudo find . -type f ! -name SHA256SUMS -exec sha256sum {} + \
    | sudo tee SHA256SUMS >/dev/null )
info "firmware: 1 WiFi + $n GPU files, checksums in /usr/lib/firmware/SHA256SUMS"

# ---------- 6. identity ----------
sudo tee "$LFS/etc/os-release" >/dev/null <<EOF
NAME="$DISTRO_NAME"
ID=$DISTRO_ID
PRETTY_NAME="$DISTRO_NAME"
BUILD_ID=rolling
EOF
printf '%s \\r (\\l)\n\n' "$DISTRO_NAME" | sudo tee "$LFS/etc/issue" >/dev/null
echo "$DISTRO_ID" | sudo tee "$LFS/etc/hostname" >/dev/null

sync
echo
info "Bootable. Next:"
info "  sudo umount -R $LFS        (never boot the VM while the image is mounted)"
info "  ~/cig/scripts/run-vm.sh"
