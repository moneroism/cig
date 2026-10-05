#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 moneroism
#
# audit-sources.sh - how every recipe's sources are authenticated, as a markdown table.
# Reads only the recipes (no downloads). Flags every source without an upstream signature,
# signed checksum file or signed git tag, and every source on a hosting mirror.

set -euo pipefail
REPO="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
cd "$REPO"

echo "| Package | Source host | Authenticity |"
echo "|---|---|---|"
ok=0 flagged=0
for r in packages/*/recipe; do
    p=$(basename "$(dirname "$r")")
    src=$(CIG_REPO=$REPO bash -c 'source= signature=; . "$1" 2>/dev/null; echo $source' _ "$r")
    sig=$(CIG_REPO=$REPO bash -c 'source= signature=; . "$1" 2>/dev/null; echo $signature' _ "$r")
    [ -n "$src" ] || continue
    read -r -a sigs <<< "$sig"
    i=0
    for e in $src; do
        url=${e#*::}
        host=$(echo "$url" | sed -E 's#^[a-z]+://([^/]+)/.*#\1#')
        s=${sigs[$i]:--}
        case "$s" in
            -)       how="**UNVERIFIED** (pinned SHA256 only, trusted on first use)" ;;
            sums=*)  how="signed checksum file" ;;
            tag=*)   how="signed git tag (archive = tag tree)" ;;
            *)       how="upstream GPG signature" ;;
        esac
        case "$host" in
            *sourceforge*|*sf.net*|*mirror*) how="**MIRROR** ($host) - $how" ;;
        esac
        case "$how" in *UNVERIFIED*|*MIRROR*) flagged=$((flagged + 1)) ;; *) ok=$((ok + 1)) ;; esac
        echo "| $p | $host | $how |"
        i=$((i + 1))
    done
done
echo
echo "$ok sources verified, $flagged flagged."
