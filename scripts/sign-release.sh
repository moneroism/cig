#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 moneroism
#
# CIG_SIGNING_KEY=<fingerprint> sign-release.sh <cig-VERSION.iso> - sign a release, run by
# the developer with their own GPG key (named explicitly: the tag and SHA256SUMS are signed by
# the same key, whatever git or gpg would pick by default):
#   1. a signed git tag vVERSION on the current commit (or checks the one that is there)
#   2. cig-release.tar.gz next to the ISO (git archive of the tag) and its detached signature
#      cig-release.tar.gz.sig: what smoke update fetches (lib/sync.sh), checked there with
#      gpgv against the keys in release-key, so the key must be listed in release-key and its
#      public half in keys/<fingerprint>.gpg, both committed before the tag
#   3. cig-VERSION.iso.xz next to the ISO: the download (GitHub takes files up to 2 GiB; the
#      ISO itself may be larger). Written with xz, which Etcher and Rufus read directly
#   4. SHA256SUMS next to the ISO, listing all three, and its detached signature SHA256SUMS.asc
# Every signature is verified before it ends. Nothing is pushed or uploaded: it prints what
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
FPR=$(gpg --with-colons --list-keys "$KEY" | awk -F: '$1 == "fpr" { print $10; exit }')
# devices accept a release only from a key in release-key: the commit must name this one
git show HEAD:release-key 2>/dev/null | awk '!/^#/ && NF { print $1 }' | grep -qx "$FPR" \
    && git cat-file -e "HEAD:keys/$FPR.gpg" 2>/dev/null \
    || die "the release key is not in this commit: echo $FPR >> release-key; gpg --export $FPR > keys/$FPR.gpg; commit both, then run this again"

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

# the archive smoke update fetches, checked as devices check it: gpgv, only the key in the tag
git archive --format=tar --prefix="cig-$VERSION/" "$TAG" | gzip -n > "$DIR/cig-release.tar.gz"
gpg --local-user "$KEY" --detach-sign --yes --output "$DIR/cig-release.tar.gz.sig" "$DIR/cig-release.tar.gz"
GV=$(mktemp -d); chmod 700 "$GV"
git show "$TAG:keys/$FPR.gpg" > "$GV/keyring.gpg"
gpgv --homedir "$GV" --keyring "$GV/keyring.gpg" --status-fd 1 "$DIR/cig-release.tar.gz.sig" "$DIR/cig-release.tar.gz" 2>/dev/null \
    | grep -q "^\[GNUPG:\] VALIDSIG .* $FPR\$" || { rm -rf "$GV"; die "cig-release.tar.gz.sig does not verify with keys/$FPR.gpg"; }
rm -rf "$GV"

cd "$DIR"
if [ ! -f "$NAME.xz" ] || [ "$NAME.xz" -ot "$NAME" ]; then
    echo "compressing $NAME (xz -9, several minutes)"
    xz -9 -T0 -k -f "$NAME"
fi
xz -t "$NAME.xz" || die "$NAME.xz is damaged"
[ "$(stat -c %s "$NAME.xz")" -lt 2147483648 ] || echo "   ! $NAME.xz is 2 GiB or more: GitHub will not take it"
sha256sum "$NAME" "$NAME.xz" cig-release.tar.gz > SHA256SUMS
gpg --local-user "$KEY" --armor --detach-sign --yes --output SHA256SUMS.asc SHA256SUMS
gpg --status-fd 1 --verify SHA256SUMS.asc SHA256SUMS 2>/dev/null | signed_by_key \
    || die "SHA256SUMS.asc does not verify with $KEY"
sha256sum -c SHA256SUMS || die "the ISO does not match SHA256SUMS"

cat <<EOF

Signed. To publish (nothing was pushed or uploaded):
  git -C $REPO push origin $TAG
  upload to the release $TAG: $NAME.xz, cig-release.tar.gz, cig-release.tar.gz.sig,
      SHA256SUMS, SHA256SUMS.asc (smoke update finds the newest release's files)
EOF
