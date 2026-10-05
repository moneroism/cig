#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 moneroism
#
# build-media.sh - the install media: a bootable USB image (cig-<version>.img).
# Run inside cig as root (the dev chroot), after building the media kernel and firmware:
#
#   CIG_VAR=/cig/media-build CIG_SOURCE_MIRROR=/var/cig/sources CIG_ROOT=PARTLABEL=cig-media \
#       cigbuild build linux
#   CIG_VAR=/cig/media-build CIG_SOURCE_MIRROR=/var/cig/sources CIG_FIRMWARE=all \
#       cigbuild build linux-firmware
#   /cig/scripts/build-media.sh [output.img]      (default: the repository, cig-<version>.img)
#
# The image: GPT with an ESP (the media kernel as EFI/BOOT/BOOTX64.EFI) and a root partition
# named cig-media (the media kernel finds root by that name, never an installed cig-root).
# The live system (cig-live) keeps the medium read-only and works in RAM; its /var/cig holds
# every source and prebuilt package: the installer's mirror. Logins: root and cig, both with
# the password ciglinux (only at the keyboard: nothing on the live system listens on the network).

set -euo pipefail
umask 022

REPO="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
VERSION=$(cat "$REPO/VERSION")
OUT=${1:-$REPO/cig-$VERSION.img}
DEV_VAR=/var/cig                  # the dev system: its packages and sources
# media kernel, firmware, the media's own builds and the staging folder: several GB, so by
# default in the repository (the host's disk in the dev chroot; git-ignored), not in the image
MEDIA_VAR=${CIG_MEDIA_VAR:-$REPO/media-build}
STAGE=$MEDIA_VAR/stage            # the live system, before it becomes a filesystem
ESP_MB=128
CIGBUILD="$REPO/cigbuild"
# the C smoke (cig-tools) with this repository's recipes; file names may contain spaces
SMOKE="${SMOKE:-/usr/share/cig/smoke}"
export CIG_REPO=$REPO CIGBUILD

die()  { echo "!! build-media: $*" >&2; exit 1; }
step() { echo "==> $*"; }

[ "$(id -u)" -eq 0 ] || die "run as root (inside the dev chroot)"
for c in mkfs.ext4 mkfs.vfat sfdisk losetup chpasswd adduser; do
    command -v "$c" >/dev/null || die "missing tool: $c"
done
for p in linux linux-firmware; do
    f=$(CIG_VAR=$MEDIA_VAR "$CIGBUILD" pkgfile "$p")
    [ -f "$f" ] || die "no media $p package ($f): build it first (see the top of this script)"
done

cleanup() {
    for m in boot dev/pts dev proc sys run; do
        mountpoint -q "$STAGE/$m" 2>/dev/null && umount "$STAGE/$m" || true
    done
}
trap cleanup EXIT

# ---- the live system ----
step "Live system in $STAGE"
cleanup
rm -rf "$STAGE" "$MEDIA_VAR/esp.img"
mkdir -p "$STAGE"/{usr/bin,usr/lib,usr/sbin,etc/cig,var/log,var/tmp,var/cig,dev,proc,sys,run,tmp,root,home,boot,mnt}
ln -s usr/bin "$STAGE/bin"; ln -s usr/lib "$STAGE/lib"; ln -s usr/sbin "$STAGE/sbin"
chmod 1777 "$STAGE/tmp" "$STAGE/var/tmp"; chmod 0750 "$STAGE/root"
cat > "$STAGE/etc/passwd" <<'EOF'
root:x:0:0:root:/root:/bin/bash
nobody:x:65534:65534:nobody:/:/bin/false
EOF
cat > "$STAGE/etc/group" <<'EOF'
root:x:0:
tty:x:5:
wheel:x:10:
audio:x:11:
video:x:12:
input:x:24:
users:x:100:
nogroup:x:65534:
EOF
printf 'root:!:20000:0:99999:7:::\nnobody:!:20000:0:99999:7:::\n' > "$STAGE/etc/shadow"
chmod 600 "$STAGE/etc/shadow"
echo cig-live > "$STAGE/etc/hostname"
printf '127.0.0.1 localhost cig-live\n::1       localhost cig-live\n' > "$STAGE/etc/hosts"
: > "$STAGE/etc/resolv.conf"
# the root is mounted read-only by the kernel; everything that changes lives in RAM (rc.init)
echo "tmpfs  /tmp  tmpfs  nosuid,nodev,noexec,mode=1777  0  0" > "$STAGE/etc/fstab"
touch "$STAGE/etc/cig/efi-fallback"     # the kernel also goes to EFI/BOOT/BOOTX64.EFI

# the media's own packages: cig-*, built for this version
step "Building the media's cig packages"
# always fresh: they are built from this repository, and their version does not change
# with every edit (an existing package file would otherwise be reused)
for p in cig-base cig-tools cig-installer cig-live; do
    rm -f "$(CIG_VAR=$MEDIA_VAR "$CIGBUILD" pkgfile "$p")"
    CIG_VAR=$MEDIA_VAR CIG_SOURCE_MIRROR=$DEV_VAR/sources "$CIGBUILD" build "$p"
done

# everything the dev system has (the media may be heavy: compilers, so installs can
# compile on the device) plus the installer and the live system; kernel and firmware
# are the media's own builds
step "Installing packages into the live system"
pkgs=$(SMOKE_ROOT= "$SMOKE" list | awk 'NR > 1 { print $1 }' | grep -vx 'linux\|linux-firmware' || true)
export CIG_VAR=$MEDIA_VAR CIG_PKG_MIRROR=$DEV_VAR/pkgs CIG_SOURCE_MIRROR=$DEV_VAR/sources
for p in linux linux-firmware $pkgs cig-installer cig-live; do
    SMOKE_ROOT=$STAGE "$SMOKE" add -p -y "$p" > /dev/null || die "could not install $p"
done
unset CIG_VAR CIG_PKG_MIRROR CIG_SOURCE_MIRROR

# the ESP: a small FAT image, mounted while the kernel hook deploys the kernel
step "EFI system partition"
truncate -s "${ESP_MB}M" "$MEDIA_VAR/esp.img"
mkfs.vfat -F 32 -n ESP "$MEDIA_VAR/esp.img" > /dev/null
mount -o loop "$MEDIA_VAR/esp.img" "$STAGE/boot"

step "Package setup and live logins"
mount --bind /dev "$STAGE/dev"; mount -t devpts devpts "$STAGE/dev/pts" 2>/dev/null || true
mount -t proc proc "$STAGE/proc"; mount -t sysfs sysfs "$STAGE/sys"; mount -t tmpfs tmpfs "$STAGE/run"
SMOKE_ROOT=$STAGE "$SMOKE" hooks --all
chroot "$STAGE" adduser -D -s /bin/bash -h /home/cig cig
for g in wheel audio video input users; do chroot "$STAGE" addgroup cig "$g"; done
printf 'root:ciglinux\ncig:ciglinux\n' | chroot "$STAGE" chpasswd -c sha512 > /dev/null
[ -f "$STAGE/boot/EFI/BOOT/BOOTX64.EFI" ] || die "the kernel did not reach the ESP"
grep -aq 'root=PARTLABEL=cig-media' "$STAGE/boot/EFI/BOOT/BOOTX64.EFI" \
    || die "the media kernel does not look for root=PARTLABEL=cig-media"
cleanup

# the installer's mirror: every source and prebuilt package (hard links, no copies);
# target kernels are always built per machine, and the generic one has its own place
step "Installer mirror (sources, packages)"
# hard links where the staging folder is on the same filesystem, copies otherwise
link() { cp -al "$@" 2>/dev/null || cp -a "$@"; }
mkdir -p "$STAGE/var/cig/sources" "$STAGE/var/cig/pkgs"
link "$DEV_VAR/sources/." "$STAGE/var/cig/sources/"
for f in "$DEV_VAR"/pkgs/*.tar.gz "$MEDIA_VAR"/pkgs/cig-*.tar.gz; do
    case "${f##*/}" in linux-[0-9]*|linux-firmware-*) continue ;; esac
    link "$f" "$STAGE/var/cig/pkgs/"
    [ -f "$f.sha256" ] && link "$f.sha256" "$STAGE/var/cig/pkgs/"
done
# the generic install kernel (root=PARTLABEL=cig-root): the all-drivers one from the media
# build if there is one, otherwise the dev system's test kernel
for g in "$MEDIA_VAR/generic" "$DEV_VAR/generic"; do
    [ -d "$g/pkgs" ] || continue
    mkdir -p "$STAGE"/var/cig/generic/{sources,build,db,logs}
    link "$g/pkgs" "$STAGE/var/cig/generic/"
    break
done

# ---- the image: GPT, ESP, cig-media (ext4 written straight from the staging folder) ----
step "Image $OUT"
root_mb=$(( $(du -sm "$STAGE" | cut -f1) * 115 / 100 + 256 ))   # 15 % + 256 MiB free
esp_s=$(( ESP_MB * 2048 )) root_s=$(( root_mb * 2048 ))
total_s=$(( 2048 + esp_s + root_s + 2048 ))
rm -f "$OUT"
truncate -s $(( total_s * 512 )) "$OUT"
sfdisk -q "$OUT" <<EOF
label: gpt
start=2048, size=$esp_s, type=uefi, name="ESP"
start=$(( 2048 + esp_s )), size=$root_s, type=linux, name="cig-media"
EOF
dd if="$MEDIA_VAR/esp.img" of="$OUT" bs=1M seek=1 conv=notrunc 2> /dev/null
mkfs.ext4 -F -q -L cig-media -E offset=$(( (2048 + esp_s) * 512 )) -d "$STAGE" "$OUT" "${root_mb}M"
rm -f "$MEDIA_VAR/esp.img"
chown "$(stat -c %u:%g "$REPO")" "$OUT"    # QEMU runs as the developer, not as root
sync
step "Done: $OUT ($(du -h "$OUT" | cut -f1) on disk, $(( total_s / 2048 )) MiB)"
echo "    QEMU: CIG_IMG=$OUT scripts/run-vm.sh      USB stick: dd if=... of=/dev/sdX bs=4M conv=fsync"
