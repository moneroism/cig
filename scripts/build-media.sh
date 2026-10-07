#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 moneroism
#
# build-media.sh - the install medium: a hybrid ISO (cig-<version>.iso) that boots through
# UEFI from CD/DVD and from a USB stick it was written to (dd). Run inside cig as root (the
# dev chroot), after building xorriso, the medium's initramfs and kernel, and the firmware:
#
#   smoke add -c -y xorriso dosfstools
#   /cig/scripts/build-initramfs.sh /cig/media-build/initramfs
#   CIG_VAR=/cig/media-build CIG_SOURCE_MIRROR=/var/cig/sources CIG_KERNEL_PROFILE=generic \
#       CIG_KERNEL_INITRAMFS=/cig/media-build/initramfs \
#       CIG_KERNEL_CMDLINE_EXTRA="console=ttyS0,115200 console=tty0" cigbuild build linux
#   CIG_VAR=/cig/media-build CIG_SOURCE_MIRROR=/var/cig/sources CIG_FIRMWARE=all \
#       cigbuild build linux-firmware
#   /cig/scripts/build-media.sh [output.iso]      (default: the repository, cig-<version>.iso)
#
# The ISO: the live system as ISO 9660 with Rock Ridge (read-only; the volume label
# CIG_<version> is what the initramfs looks for), and an EFI system partition image with the
# medium's kernel as EFI/BOOT/BOOTX64.EFI, used for El Torito (CD/DVD) and appended as a GPT
# partition (USB stick). The kernel's built-in initramfs (scripts/initramfs/init) finds the
# ISO by its label, mounts it and starts the live system.
# The live system (cig-live) keeps the medium read-only and works in RAM; its /var/cig holds
# every source and prebuilt package: the installer's mirror. Logins: root and cig, both with
# the password ciglinux (only at the keyboard: nothing on the live system listens on the network).

set -euo pipefail
umask 022

REPO="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
VERSION=$(cat "$REPO/VERSION")
OUT=${1:-$REPO/cig-$VERSION.iso}
LABEL="CIG_${VERSION//./_}"       # the ISO's volume label: scripts/build-initramfs.sh uses the same
DEV_VAR=/var/cig                  # the dev system: its packages and sources
# media kernel, firmware, the media's own builds and the staging folder: several GB, so by
# default in the repository (the host's disk in the dev chroot; git-ignored), not in the image
MEDIA_VAR=${CIG_MEDIA_VAR:-$REPO/media-build}
STAGE=$MEDIA_VAR/stage            # the live system, before it becomes a filesystem
ESP_MB=30       # El Torito records the boot image size in 512-byte sectors (16 bits): at most 32 MiB
CIGBUILD="$REPO/cigbuild"
# the C smoke (cig-tools) with this repository's recipes; file names may contain spaces
SMOKE="${SMOKE:-/usr/share/cig/smoke}"
export CIG_REPO=$REPO CIGBUILD

die()  { echo "!! build-media: $*" >&2; exit 1; }
step() { echo "==> $*"; }

[ "$(id -u)" -eq 0 ] || die "run as root (inside the dev chroot)"
for c in xorriso mkfs.fat losetup chpasswd adduser; do
    command -v "$c" >/dev/null || die "missing tool: $c"
done
for p in linux linux-firmware; do
    f=$(CIG_VAR=$MEDIA_VAR "$CIGBUILD" pkgfile "$p")
    [ -f "$f" ] || die "no media $p package ($f): build it first (see the top of this script)"
done

# the installer's prebuilt packages must match the recipes: a component (group=), or any
# package built before, whose current version-rel has no package is built now (smoke
# update only rebuilds what the dev system has installed; fastfetch was missed once)
stale=
for r in "$REPO"/packages/*/recipe; do
    p=${r%/recipe}; p=${p##*/}
    case " linux linux-firmware cig-base cig-tools cig-installer cig-live pixel " in *" $p "*) continue ;; esac
    if ! grep -q '^group=' "$r" && ! ls "$DEV_VAR/pkgs/$p"-[0-9]*.tar.gz >/dev/null 2>&1; then continue; fi
    [ -f "$("$CIGBUILD" pkgfile "$p")" ] || stale="$stale $p"
done
if [ -n "$stale" ]; then
    step "Building prebuilt packages that are missing or older than their recipe:$stale"
    for p in $stale; do "$CIGBUILD" build "$p"; done
fi

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
REPO_PKGS="cig-base cig-tools cig-installer cig-live pixel"
for p in $REPO_PKGS; do
    rm -f "$(CIG_VAR=$MEDIA_VAR "$CIGBUILD" pkgfile "$p")"
    CIG_VAR=$MEDIA_VAR CIG_SOURCE_MIRROR=$DEV_VAR/sources "$CIGBUILD" build "$p"
done

# every package the installer can install must declare the libraries it links (an
# undeclared one breaks installs with another selection: file/liblzma, mesa/libdisplay-info)
step "Declared dependencies of every package"
set --
for r in "$REPO"/packages/*/recipe; do
    p=${r%/recipe}; p=${p##*/}
    case " linux linux-firmware " in *" $p "*) continue ;; esac
    case " $REPO_PKGS " in
        *" $p "*) f=$(CIG_VAR=$MEDIA_VAR "$CIGBUILD" pkgfile "$p") ;;
        *)        f=$("$CIGBUILD" pkgfile "$p") ;;
    esac
    [ ! -f "$f" ] || set -- "$@" "$f"
done
"$REPO/scripts/check-deps.sh" "$@" || die "packages link libraries they do not declare (above)"

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
mkfs.fat -F 16 -n ESP "$MEDIA_VAR/esp.img" > /dev/null   # FAT16 (UEFI reads it; dosfstools)
mount -o loop "$MEDIA_VAR/esp.img" "$STAGE/boot"

step "Package setup and live logins"
mount --bind /dev "$STAGE/dev"; mount -t devpts devpts "$STAGE/dev/pts" 2>/dev/null || true
mount -t proc proc "$STAGE/proc"; mount -t sysfs sysfs "$STAGE/sys"; mount -t tmpfs tmpfs "$STAGE/run"
SMOKE_ROOT=$STAGE "$SMOKE" hooks --all
chroot "$STAGE" adduser -D -s /bin/bash -h /home/cig cig
for g in wheel audio video input users; do chroot "$STAGE" addgroup cig "$g"; done
printf 'root:ciglinux\ncig:ciglinux\n' | chroot "$STAGE" chpasswd -c sha512 > /dev/null
# every program on the live system must find its libraries (gpgv once linked libassuan and
# npth, which only the dev system had as build tools)
libs=$(SMOKE_ROOT=$STAGE "$SMOKE" audit --quick 2>&1 | grep ' needs ' || true)
[ -z "$libs" ] || { echo "$libs" >&2; die "programs on the live system miss libraries (above)"; }
[ -f "$STAGE/boot/EFI/BOOT/BOOTX64.EFI" ] || die "the kernel did not reach the ESP"
[ "$(df -k "$STAGE/boot" | awk 'NR == 2 { print $4 }')" -gt 1024 ] \
    || die "the ESP image ($ESP_MB MiB, the El Torito limit) is full: the kernel is too large for it"
cleanup

# every signed source's signature next to it, so an install can compile offline and still
# check each source with gpgv (the dev system has signatures only for what it built since
# gpgv came). Not fatal: a host that does not answer only costs the offline check there.
step "Signatures for the installer mirror"
miss=
for r in "$REPO"/packages/*/recipe; do
    p=${r%/recipe}; p=${p##*/}
    grep -q '^signature="[^-]' "$r" || continue
    CIG_VAR=$DEV_VAR "$CIGBUILD" fetch "$p" > /dev/null 2>&1 || miss="$miss $p"
done
[ -z "$miss" ] || echo "    not fetched (an offline compile of these needs the network):$miss"

# the installer's mirror: every source and prebuilt package (hard links, no copies);
# target kernels are always built per machine, and the generic one has its own place
step "Installer mirror (sources, packages)"
# hard links where the staging folder is on the same filesystem, copies otherwise
link() { cp -al "$@" 2>/dev/null || cp -a "$@"; }
mkdir -p "$STAGE/var/cig/sources" "$STAGE/var/cig/pkgs"
link "$DEV_VAR/sources/." "$STAGE/var/cig/sources/"
for f in "$DEV_VAR"/pkgs/*.tar.gz $(for p in $REPO_PKGS; do echo "$MEDIA_VAR/pkgs/$p-[0-9]*.tar.gz"; done); do
    [ -f "$f" ] || continue
    case "${f##*/}" in linux-[0-9]*|linux-firmware-*) continue ;; esac
    link "$f" "$STAGE/var/cig/pkgs/"
    [ -f "$f.sha256" ] && link "$f.sha256" "$STAGE/var/cig/pkgs/"
done
# the generic install kernel (root=PARTLABEL=cig-root): the all-drivers one from the media
# build if there is one, otherwise the dev system's test kernel
for g in "$MEDIA_VAR/generic" "$DEV_VAR/generic"; do
    ls "$g"/pkgs/linux-[0-9]*.tar.gz >/dev/null 2>&1 || continue   # a folder without a kernel does not count
    mkdir -p "$STAGE"/var/cig/generic/{sources,build,db,logs}
    link "$g/pkgs" "$STAGE/var/cig/generic/"
    break
done

# ---- the ISO: Rock Ridge (owners, modes, links as they are), the ESP image for El Torito
# and as an appended GPT partition (the same file: UEFI finds it on a CD and on a USB stick)
step "ISO $OUT ($LABEL)"
rm -f "$OUT"
xorriso -as mkisofs -o "$OUT" -V "$LABEL" -iso-level 3 -R \
    -append_partition 2 0xef "$MEDIA_VAR/esp.img" -appended_part_as_gpt \
    -e --interval:appended_partition_2:all:: -no-emul-boot \
    "$STAGE" 2> "$MEDIA_VAR/xorriso.log" || { tail -n 20 "$MEDIA_VAR/xorriso.log" >&2; die "xorriso failed"; }
rm -f "$MEDIA_VAR/esp.img"
chown "$(stat -c %u:%g "$REPO")" "$OUT"    # QEMU runs as the developer, not as root
sync
step "Done: $OUT ($(du -h "$OUT" | cut -f1))"
echo "    QEMU as a CD: CIG_CDROM=$OUT scripts/run-vm.sh     as a disk: CIG_IMG=$OUT scripts/run-vm.sh"
echo "    USB stick: dd if=$OUT of=/dev/<the stick> bs=4M conv=fsync"
