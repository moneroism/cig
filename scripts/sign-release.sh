#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 moneroism
#
# CIG_SIGNING_KEY=<fingerprint> sign-release.sh <cig-VERSION.iso> - sign a release, run by
# the developer with their own GPG key (named explicitly: the tag and SHA256SUMS are signed by
# the same key, whatever git or gpg would pick by default):
#   1. a signed git tag vVERSION on the current commit (or checks the one that is there)
#   2. SHA256SUMS next to the ISO, listing it, and its detached signature SHA256SUMS.asc
# Both signatures are verified before it ends. Nothing is pushed or uploaded: it prints what
# to publish. Users check a release as README ("Verifying a release") describes.
set -euo pipefail
die() { echo "sign-release: $*" >&2; exit 1; }
REPO="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
ISO=$(readlink -f "${1:?usage: CIG_SIGNING_KEY=<fingerprint> sign-release.sh <cig-VERSION.iso>}")
KEY=${CIG_SIGNING_KEY:?set CIG_SIGNING_KEY to the fingerprint of the release key}
VERSION=$(cat "$REPO/VERSION")
TAG=v$VERSION
NAME=${ISO##*/}
DIR=${ISO%/*}

[ -f "$ISO" ] || die "$ISO: no such file"
[ "$NAME" = "cig-$VERSION.iso" ] || die "$NAME: expected cig-$VERSION.iso (VERSION says $VERSION)"
cd "$REPO"
# the tag must name what was built: no changes to tracked files (untracked ones do not count)
[ -z "$(git status --porcelain --untracked-files=no)" ] \
    || die "tracked files have uncommitted changes: commit or stash them, and build the ISO from that commit"
gpg --list-secret-keys "$KEY" > /dev/null 2>&1 || die "no secret key $KEY in gpg's keyring"

if git rev-parse -q --verify "refs/tags/$TAG" > /dev/null; then
    [ "$(git rev-parse "$TAG^{commit}")" = "$(git rev-parse HEAD)" ] \
        || die "tag $TAG already exists on another commit ($(git rev-parse --short "$TAG^{commit}"))"
    echo "tag $TAG exists on this commit"
else
    git tag --local-user "$KEY" -m "cig $VERSION" "$TAG"
    echo "tag $TAG made"
fi
# a valid signature, by this key (primary or subkey fingerprint, or the ID given)
signed_by_key() { grep -qi "^\[GNUPG:\] VALIDSIG .*${KEY#0x}"; }
git verify-tag --raw "$TAG" 2>&1 | signed_by_key || die "tag $TAG has no valid signature by $KEY"

cd "$DIR"
sha256sum "$NAME" > SHA256SUMS
gpg --local-user "$KEY" --armor --detach-sign --yes --output SHA256SUMS.asc SHA256SUMS
gpg --status-fd 1 --verify SHA256SUMS.asc SHA256SUMS 2>/dev/null | signed_by_key \
    || die "SHA256SUMS.asc does not verify with $KEY"
sha256sum -c SHA256SUMS || die "the ISO does not match SHA256SUMS"

cat <<EOF

Signed. To publish (nothing was pushed or uploaded):
  git -C $REPO push origin $TAG
  upload to the release $TAG: $NAME, SHA256SUMS, SHA256SUMS.asc
EOF
