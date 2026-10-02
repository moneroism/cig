#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 moneroism
# prepare-base.sh - run on VOID (not in the chroot), as your normal user.
#
# The chroot has no network, so anything new is fetched here and copied in.
# Fetches sinit (pinned tag), copies build-base.sh into /mnt/lfs/sources.

set -euo pipefail

LFS=/mnt/lfs
SINIT_TAG=v1.1
HERE="$(cd "$(dirname "$0")" && pwd)"
STAGE="$HOME/cig/stage"

die() { echo "!! $*" >&2; exit 1; }

[ "$(id -u)" -ne 0 ] || die "run as your normal user"
mountpoint -q "$LFS" || die "$LFS is not mounted"
[ -f "$LFS/etc/.handed-to-root" ] || die "enter the chroot once first (enter-chroot.sh)"
[ -f "$HERE/build-base.sh" ] || die "build-base.sh must be next to this script"
command -v git >/dev/null || die "git is not installed"

mkdir -p "$STAGE"
rm -rf "$STAGE/sinit"
echo "==> fetching sinit $SINIT_TAG"
git clone --quiet --depth 1 --branch "$SINIT_TAG" https://git.suckless.org/sinit "$STAGE/sinit"
SINIT_COMMIT=$(git -C "$STAGE/sinit" rev-parse HEAD)
echo "==> sinit $SINIT_TAG = commit $SINIT_COMMIT"
rm -rf "$STAGE/sinit/.git"

echo "==> copying into $LFS/sources (sudo)"
sudo rm -rf "$LFS/sources/sinit"
sudo cp -r "$STAGE/sinit" "$LFS/sources/sinit"
sudo install -m 755 "$HERE/build-base.sh" "$LFS/sources/build-base.sh"

if ! sudo grep -q '^SINIT_TAG=' "$LFS/sources/VERSIONS"; then
    printf 'SINIT_TAG=%s\nSINIT_COMMIT=%s\n' "$SINIT_TAG" "$SINIT_COMMIT" \
        | sudo tee -a "$LFS/sources/VERSIONS" >/dev/null
fi
sudo chown -R root:root "$LFS/sources/sinit"

echo
echo "==> ready. Now:"
echo "    sudo ~/cig/scripts/enter-chroot.sh"
echo "    bash /sources/build-base.sh"
