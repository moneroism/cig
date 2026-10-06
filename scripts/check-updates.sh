#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 moneroism
#
# check-updates.sh - which recipes are behind their upstream's newest stable release.
# Runs `cigbuild latest` for every recipe (8 at a time) and prints a table; recipes with
# track= stay within their series (the reasons are in the recipes and in README).
# Updating a recipe: set the new version, clear sha256=, then cigbuild pin and cigbuild sig.

set -euo pipefail
REPO="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
export CIG_REPO=$REPO CIG_VAR=${CIG_VAR:-$HOME/.cache/cig}
cd "$REPO/packages"

# recipes without a downloaded source (cig's own, meta packages) have nothing to check
mapfile -t pkgs < <(for p in *; do grep -q '^source="[^"]' "$p/recipe" 2>/dev/null && echo "$p"; done)
out=$(printf '%s\n' "${pkgs[@]}" | xargs -P 8 -n 1 "$REPO/cigbuild" latest 2>/dev/null | sort)

echo "| Package | Recipe | Upstream | |"
echo "|---|---|---|---|"
echo "$out" | awk '{ mark = $4 == "update" ? "**update**" : $4 == "unknown" ? "unknown" : "";
                     t = ""; cmd = "grep -m1 \"^track=\" " $1 "/recipe"; cmd | getline t; close(cmd)
                     if (t != "") { sub(/^track=/, "", t); mark = mark (mark ? ", " : "") "track " t }
                     print "| " $1 " | " $2 " | " $3 " | " mark " |" }'
echo
echo "$(echo "$out" | grep -c ' update$' || true) behind, $(echo "$out" | grep -c ' current$' || true) current, $(echo "$out" | grep -c ' unknown$' || true) unknown."
