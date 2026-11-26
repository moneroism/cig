#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 moneroism
#
# publish-packages.sh - put the current prebuilt packages into cig's package pool: the release
# "packages" of the GitHub repository moneroism/pool (CIG_POOL_REPO), with a new INDEX signed by
# a cig release key (lib/pool.sh explains what devices check). Run on the host by the owner of a
# release key, with the dev image mounted and GitHub's gh logged in:
#
#   scripts/publish-packages.sh [<dev system's /var/cig>]       default /mnt/cig/var/cig
#
# Published: each recipe's current package file (cigbuild pkgfile) from the dev system's
# packages; cig's own packages (cig-base, cig-tools, cig-check, pixel, clock) from media-build,
# where build-media makes them for this version. Never: the kernel and the firmware (made for
# each machine), the installer and the live system (media only). A file already in the pool is
# never replaced: devices may have checked it; a changed package needs a new rel.
# The index lists every file in the pool, old ones too (an installed older cig release still
# finds its packages). It is signed and checked with gpgv before anything is uploaded, and
# uploaded last, after the files it names.
set -euo pipefail
die() { echo "publish-packages: $*" >&2; exit 1; }
REPO="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
DEV=${1:-/mnt/cig/var/cig}
POOL=${CIG_POOL_REPO:-moneroism/pool}
TAG=packages
MEDIA_PKGS="$REPO/media-build/pkgs"
OWN="cig-base cig-tools cig-check pixel clock"
SKIP="linux linux-firmware cig-installer cig-live"

[ -d "$DEV/pkgs" ] || die "$DEV/pkgs: no such folder (mount the dev image: see CLAUDE.md, or name its /var/cig)"
command -v gh > /dev/null || die "gh is not installed (sudo xbps-install -S github-cli; gh auth login)"
gh auth status > /dev/null 2>&1 || die "gh is not logged in: gh auth login"
FPR=$(awk '!/^#/ && NF { print $1; exit }' "$REPO/release-key")
[ -n "$FPR" ] && [ -s "$REPO/keys/$FPR.gpg" ] || die "no release key in release-key and keys/"
gpg --list-secret-keys "$FPR" > /dev/null 2>&1 || die "no secret key $FPR in gpg's keyring"

W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
mkdir -m 700 "$W/gv"
for k in $(awk '!/^#/ && NF { print $1 }' "$REPO/release-key"); do cat "$REPO/keys/$k.gpg" >> "$W/gv/keyring.gpg"; done
verify() { gpgv --homedir "$W/gv" --keyring "$W/gv/keyring.gpg" --status-fd 1 "$1" "$2" 2>/dev/null | grep -q '^\[GNUPG:\] VALIDSIG '; }

# ---- the pool as it is: its index (verified), its files
if gh release view "$TAG" --repo "$POOL" > /dev/null 2>&1; then
    gh release download "$TAG" --repo "$POOL" --pattern INDEX --pattern INDEX.sig --dir "$W" > /dev/null 2>&1 || true
    if [ -f "$W/INDEX" ]; then
        verify "$W/INDEX.sig" "$W/INDEX" || die "the pool's current INDEX does not verify with a release key: look at it before publishing"
        echo "pool: $(awk '!/^#/ && NF == 4' "$W/INDEX" | wc -l) packages listed"
    fi
    gh release view "$TAG" --repo "$POOL" --json assets --jq '.assets[].name' > "$W/assets"
else
    # a release needs a commit to tag: an empty repository gets a README first
    if [ "$(gh api "repos/$POOL" --jq .size)" = 0 ]; then
        printf '# cig package pool\n\nPrebuilt packages for [cig](https://github.com/moneroism/cig), in the release `%s`.\nDevices use a package only when its SHA256 matches `INDEX`, which is signed by a cig\nrelease key (see `release-key` in the cig repository).\n' "$TAG" \
            | base64 -w0 > "$W/readme.b64"
        gh api -X PUT "repos/$POOL/contents/README.md" -f message="cig package pool" -F content=@"$W/readme.b64" > /dev/null \
            || die "could not create the first commit in $POOL"
    fi
    gh release create "$TAG" --repo "$POOL" --title "cig package pool" \
        --notes "Prebuilt cig packages. Devices check every file against INDEX (signed by a cig release key; INDEX.sig)." > /dev/null \
        || die "could not create the release $TAG in $POOL"
    echo "pool: release $TAG created in $POOL"
    : > "$W/assets"
fi
[ -f "$W/INDEX" ] || printf '# cig package pool index (scripts/publish-packages.sh)\n' > "$W/INDEX"

# ---- what to publish: each recipe's current package file
: > "$W/new"; : > "$W/upload"; kept=0; skipped=
for r in "$REPO"/packages/*/recipe; do
    p=${r%/recipe}; p=${p##*/}
    case " $SKIP " in *" $p "*) continue ;; esac
    base=$(CIG_VAR="$W/var" "$REPO/cigbuild" pkgfile "$p" 2>/dev/null) || continue
    base=${base##*/}
    case " $OWN " in *" $p "*) f="$MEDIA_PKGS/$base" ;; *) f="$DEV/pkgs/$base" ;; esac
    [ -f "$f" ] || { skipped="$skipped $p"; continue; }
    sha=$(sha256sum "$f" | cut -d' ' -f1)
    old=$(awk -v f="$base" '!/^#/ && $1 == f { print $2; exit }' "$W/INDEX")
    if [ -n "$old" ]; then
        [ "$old" = "$sha" ] || echo "   ! $base: the pool has other content under this name (kept; bump $p's rel to publish this build)"
        kept=$((kept + 1))
        grep -qx "$base" "$W/assets" || echo "$f" >> "$W/upload"   # listed, but its upload had failed
        continue
    fi
    kib=$(tar -xzOf "$f" ./.PKGINFO 2>/dev/null | sed -n 's/^size=//p')
    echo "$base $sha $p ${kib:-0}" >> "$W/new"
    echo "$f" >> "$W/upload"
done
[ -z "$skipped" ] || echo "no package for the current recipe (not published):$skipped" | fold -s -w 100
echo "new: $(wc -l < "$W/new") package files; already in the pool: $kept"
[ -s "$W/upload" ] || [ -s "$W/new" ] || { echo "nothing to publish"; exit 0; }

# ---- the new index: the old entries, the new ones, a newer date; signed and checked
{
    printf '# cig package pool index (scripts/publish-packages.sh)\n'
    printf 'date %s\n' "$(date +%s)"
    awk '!/^#/ && NF == 4' "$W/INDEX"
    cat "$W/new"
} > "$W/INDEX.new"
mv "$W/INDEX.new" "$W/INDEX"
rm -f "$W/INDEX.sig"
gpg --local-user "$FPR" --detach-sign --output "$W/INDEX.sig" "$W/INDEX"
verify "$W/INDEX.sig" "$W/INDEX" || die "the new INDEX.sig does not verify with the release keys"
awk '!/^#/ && NF == 4 { print $1 }' "$W/INDEX" | sort | uniq -d | grep -q . && die "INDEX lists a file twice"

# ---- upload: the files, then the index
n=$(wc -l < "$W/upload"); i=0
while read -r f; do
    i=$((i + 1)); echo "[$i/$n] ${f##*/}"
    gh release upload "$TAG" "$f" --repo "$POOL" > /dev/null || die "upload failed: ${f##*/} (run again: what is uploaded is kept)"
done < "$W/upload"
gh release upload "$TAG" "$W/INDEX" "$W/INDEX.sig" --repo "$POOL" --clobber > /dev/null || die "the index upload failed (run again)"

# every file the index names must be in the release under exactly that name
gh release view "$TAG" --repo "$POOL" --json assets --jq '.assets[].name' > "$W/assets"
missing=$(awk '!/^#/ && NF == 4 { print $1 }' "$W/INDEX" | grep -vxF -f "$W/assets" || true)
[ -z "$missing" ] || die "the release lacks files the index names: $missing"
echo "published: $(awk '!/^#/ && NF == 4' "$W/INDEX" | wc -l) package files in $POOL ($TAG), index signed by $FPR"
