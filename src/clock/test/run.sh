#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 moneroism
# run.sh - builds clock in a temporary folder (never in the checkout) with the strongest checks
# the compiler has (address + undefined-behaviour sanitizers, else undefined behaviour as traps)
# and lets test/check.py run it on pseudo terminals of many sizes: the picture must fit the
# window and show the current time. On cig, /tmp is mounted noexec: TMPDIR=~/tmp bash run.sh
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
built=
for san in "-fsanitize=address,undefined -fno-sanitize-recover=all" "-fsanitize=undefined -fsanitize-trap=all" ""; do
    if cc -std=c17 -O1 -g -Wall -Wextra $san -o "$t/clock" ../clock.c 2>"$t/err"; then
        built=1
        echo "run.sh: built with ${san:-no sanitizer}"
        break
    fi
done
[ -n "$built" ] || { cat "$t/err"; exit 1; }
exec python3 check.py "$t/clock"
