#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 moneroism
# fetch-sources.sh - get the upstream sources this repo does not contain,
# at exactly the versions pinned in record/. Run on the host, normal user.
#
#   linux-hardened  -> tag from record/kernel-source.txt (signature checked)
#   linux-firmware  -> commit from record/firmware-commit.txt
#
# If the folders already exist, it only checks that they match the record.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KTAG=$(tr -d ' \n' < "$ROOT/record/kernel-source.txt")
FWCOMMIT=$(tr -d ' \n' < "$ROOT/record/firmware-commit.txt")
export GNUPGHOME="$ROOT/stage/.gnupg-sources"

die()  { echo; echo "!! $*" >&2; exit 1; }
info() { echo "==> $*"; }

[ "$(id -u)" -ne 0 ] || die "run as your normal user"
command -v git >/dev/null || die "git is not installed"
mkdir -p "$GNUPGHOME"; chmod 700 "$GNUPGHOME"

# ---------- linux-hardened ----------
K="$ROOT/linux-hardened"
if [ -d "$K/.git" ]; then
    have=$(git -C "$K" describe --tags)
    [ "$have" = "$KTAG" ] || die "linux-hardened is at $have, record says $KTAG"
    info "linux-hardened: at $KTAG (matches record)"
else
    info "cloning linux-hardened $KTAG (shallow)"
    git clone --quiet --depth 1 --branch "$KTAG" https://github.com/anthraxx/linux-hardened.git "$K"
fi

info "checking the tag signature"
out=$(git -C "$K" verify-tag --raw "$KTAG" 2>&1 || true)
if echo "$out" | grep -q NO_PUBKEY; then
    key=$(echo "$out" | awk '/NO_PUBKEY/ {print $3; exit}')
    for ks in hkps://keyserver.ubuntu.com hkps://keys.openpgp.org; do
        gpg --keyserver "$ks" --recv-keys "$key" >/dev/null 2>&1 && break
    done
    out=$(git -C "$K" verify-tag --raw "$KTAG" 2>&1 || true)
fi
if echo "$out" | grep -q VALIDSIG; then
    info "tag $KTAG signed by key $(echo "$out" | awk '/VALIDSIG/ {print $3; exit}')"
elif echo "$out" | grep -q BADSIG; then
    die "BAD SIGNATURE on tag $KTAG"
else
    echo "!! WARNING: tag $KTAG carries no verifiable signature."
    echo "   Verify the release tarball's .sig from the GitHub release page instead."
fi

# ---------- linux-firmware ----------
F="$ROOT/linux-firmware"
if [ -d "$F/.git" ]; then
    have=$(git -C "$F" rev-parse HEAD)
    [ "$have" = "$FWCOMMIT" ] || die "linux-firmware is at $have, record says $FWCOMMIT"
    info "linux-firmware: at pinned commit (matches record)"
else
    info "fetching linux-firmware at commit $FWCOMMIT (shallow)"
    mkdir -p "$F"
    git -C "$F" init --quiet
    git -C "$F" remote add origin https://gitlab.com/kernel-firmware/linux-firmware.git
    git -C "$F" fetch --quiet --depth 1 origin "$FWCOMMIT"
    git -C "$F" checkout --quiet FETCH_HEAD
fi
echo "   (linux-firmware commits are not signed upstream; the commit hash is the pin)"

info "sources ready"
